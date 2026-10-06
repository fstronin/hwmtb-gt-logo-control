# Подсветка логотипа HUAWEI на крышке MateBook GT 14 под Linux

Управление «Logo-灯» (подсветка литого логотипа HUAWEI на крышке) из Linux
на HUAWEI MateBook GT 14 (`ENZH-XX`, BIOS 1.16, Insyde, EC Microchip MEC1930) —
без Windows и без Huawei PC Manager.

Ставится как обычный пакет Debian/Ubuntu: DKMS-модуль собирается на месте,
подписывается вашим MOK-ключом (Secure Boot можно не выключать).

```
sudo apt install ./hwlogo_1.0.1_all.deb

hwlogo on        # включить
hwlogo off       # выключить
hwlogo toggle
hwlogo status
Logo light: включён (brightness=255)
EC[0xa4]=0x02
```

То же через стандартный LED-интерфейс (скрипты, `brightnessctl`, «моргание»):

```
echo 1 > /sys/class/leds/huawei::logo/brightness
cat  /sys/class/leds/huawei::logo/ec        # EC-регистр состояния
```

## Сборка пакета

```
./build-deb.sh          # → ../hwlogo_1.0.0_all.deb
```

Нужен только `dpkg-dev` (никакого debhelper: `debian/rules` написан вручную).
Версия берётся из `debian/changelog` и подставляется в `dkms.conf` и
maintainer-скрипты — чтобы выпустить новую версию, достаточно добавить запись
в changelog (`dch -i` или вручную) и пересобрать:

```
sudo apt install --reinstall ./hwlogo_<новая версия>_all.deb
```

## Что делает пакет

| Файл | Назначение |
|---|---|
| `/usr/src/hwlogo-<ver>/{hwlogo.c,Makefile,dkms.conf}` | исходники модуля для DKMS |
| `/usr/bin/hwlogo` | CLI (`on`/`off`/`toggle`/`status`) |
| `/usr/lib/udev/rules.d/90-hwlogo.rules` | даёт группе `plugdev` доступ к `brightness` |
| `/etc/modules-load.d/hwlogo.conf` | автозагрузка модуля |
| `/usr/lib/systemd/system/hwlogo-restore.service` | опционально: применять состояние при загрузке |
| `/usr/lib/hwlogo/{hwec-call,find_logo.sh}` | инструменты отладки/повторного поиска регистров (нужен `acpi-call-dkms`) |
| `/usr/share/doc/hwlogo/README.md` | этот файл |

Состояние подсветки — это состояние EC, поэтому оно **не меняется** при
выгрузке модуля, обновлении или удалении пакета (у LED-устройства выставлен
флаг `LED_RETAIN_AT_SHUTDOWN`, иначе LED-ядро гасит светодиод при
`led_classdev_unregister()`).

`postinst` вызывает `/usr/lib/dkms/common.postinst` (сборка+подпись+установка
для всех установленных ядер, пересборка при обновлении ядра через
`/etc/kernel/postinst.d/dkms`), затем `udevadm` и `modprobe`.
`prerm` делает `dkms remove` и выгружает модуль; `postrm purge` чистит
`/var/lib/dkms/hwlogo`.

Удаление: `sudo apt purge hwlogo` (плюс, при желании,
`sudo apt remove acpi-call-dkms` — он нужен был только для отладки).

## Что было выяснено (реверс-инжиниринг прошивки)

1. Логотип управляется **встроенным контроллером (EC)**. В ACPI/WMI команды для
   него нет: в SSDT18 («HUAWEI WmiTable») методы `SLED`/`GLED` — заглушки
   (`Function logic to be implemented!!!`), а `SLGO`/`GLGO` («Customized Logo»)
   через SMI — это логотип загрузки BIOS, не подсветка крышки.
2. Есть штатная WMI-пара прошивки **`GLGS`/`SLGS`** (коды `0x0509`/`0x050A`),
   реализованная как два регистра EC:

   | Регистр | Смысл | Значения |
   |---|---|---|
   | `0xA4` | состояние (GLGS) | `0x01` = выкл, `0x02` = вкл |
   | `0xA5` | установка (SLGS) | `0x00` = выкл, `0x01` = вкл |

   Другие значения, записанные в `0xA5`, игнорируются.
3. До EC прошивка ходит методом `\_SB.PC00.LPCB.HWEC.ECCD(cmd, off, len, data, retlen)` —
   mailbox на портах `0x68` (данные) / `0x6C` (состояние), `cmd=0x02` = EC RAM.
   Ответ: `[status, length, data…]`, где `status=0` — успех, `0x01` — регистра
   нет, `0x20` — запись отклонена.
4. Secure Boot включён ⇒ ядро в `lockdown=integrity`, что запрещает `ioperm`,
   `/dev/port`, `/dev/mem`, неподписанные модули и «опасные» параметры модулей
   (`ec_sys write_support=1` тоже отбивается). Поэтому доступ идёт через сам
   firmware-метод `ECCD` из подписанного DKMS-модуля — Secure Boot не тронут.

## Состояние и загрузка

`0xA4`/`0xA5` — RAM EC, поэтому состояние может сбрасываться при полном
снятии питания (проверьте перезагрузкой; после выключения/включения и после
сброса EC возможен возврат к значению по умолчанию). Чтобы гарантировать
состояние после **каждой** загрузки:

```
sudo systemctl enable --now hwlogo-restore.service   # ExecStart=/usr/bin/hwlogo on
```

## Ограничения

* Проверено на MateBook GT 14 (`ENZH-XX`), BIOS `1.16` (22.07.2025). На других
  MateBook адреса могут отличаться — проверяйте
  `bash /usr/lib/hwlogo/hwec-call rd 0xa4` (нужен `acpi-call-dkms`).
* Параметры модуля можно менять без пересборки через `/etc/modprobe.d/`:
  `reg` (по умолчанию `0xA5`), `state_reg` (`0xA4`), `on_value` (`0x01`),
  `off_value` (`0x00`).
* Для справки, другие найденные регистры EC этой модели: `0x64`/`0x65` —
  яркость подсветки клавиатуры (0/2/4), `0x6B`/`0x6C` — Fn-Lock (`0x55`/`0x5A`),
  `0x77` — LED микрофона (`0x55`/`0x5A`), `0x7A`/`0x7B` — режим вентилятора,
  `0x9C`/`0x9D` — таймаут подсветки клавиатуры.
