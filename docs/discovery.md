# HUAWEI logo backlight on the MateBook GT 14 lid under Linux

> English discovery log. The Russian original is kept as `docs/discovery.ru.md`.

Controlling the "Logo light" (the illuminated cast HUAWEI wordmark on the lid)
from Linux on a HUAWEI MateBook GT 14 (`ENZH-XX`, BIOS 1.16, Insyde,
EC Microchip MEC1930) — without Windows and without Huawei PC Manager.

It installs as an ordinary Debian/Ubuntu package: the DKMS module is built
locally and signed with your MOK key (Secure Boot can stay enabled).

```
sudo apt install ./dist/hwlogo_<version>_all.deb

hwlogo on        # turn on
hwlogo off       # turn off
hwlogo toggle
hwlogo status
Logo light: on (brightness=255)
EC[0xa4]=0x02
```

The same via the standard LED interface (scripts, `brightnessctl`, "blinking"):

```
echo 1 > /sys/class/leds/huawei::logo/brightness
cat  /sys/class/leds/huawei::logo/ec        # EC state register
```

## Building the package

```
./build-deb.sh          # → dist/hwlogo_<version>_all.deb
```

Only `dpkg-dev` is required (no debhelper: `debian/rules` is hand-written).
The version comes from `debian/changelog` and is substituted into `dkms.conf`
and the maintainer scripts — so to release a new version it is enough to add an
entry to the changelog (`dch -i` or by hand) and rebuild:

```
sudo apt install --reinstall ./hwlogo_<new version>_all.deb
```

## What the package does

| File | Purpose |
|---|---|
| `/usr/src/hwlogo-<ver>/{hwlogo.c,Makefile,dkms.conf}` | module sources for DKMS |
| `/usr/bin/hwlogo` | CLI (`on`/`off`/`toggle`/`status`) |
| `/usr/lib/udev/rules.d/90-hwlogo.rules` | grants the `plugdev` group access to `brightness` |
| `/etc/modules-load.d/hwlogo.conf` | module autoload |
| `/usr/lib/systemd/system/hwlogo-restore.service` | optional: apply the state at boot |
| `/usr/lib/hwlogo/{hwec-call,find_logo.sh}` | debugging / register re-discovery tools (needs `acpi-call-dkms`) |
| `/usr/share/doc/hwlogo/README.md` | this file |

The backlight state is EC state, so it does **not change** when the module is
unloaded, upgraded or the package is removed (the LED device is flagged
`LED_RETAIN_AT_SHUTDOWN`, otherwise the LED core turns the LED off in
`led_classdev_unregister()`).

`postinst` calls `/usr/lib/dkms/common.postinst` (build+sign+install for every
installed kernel, rebuilt on kernel upgrades via `/etc/kernel/postinst.d/dkms`),
then `udevadm` and `modprobe`. `prerm` runs `dkms remove` and unloads the module;
`postrm purge` cleans up `/var/lib/dkms/hwlogo`.

Removal: `sudo apt purge hwlogo` (plus, optionally,
`sudo apt remove acpi-call-dkms` — it was only needed for debugging).

## What was discovered (firmware reverse engineering)

1. The logo is controlled by the **embedded controller (EC)**. There is no
   ACPI/WMI command for it: in SSDT18 ("HUAWEI WmiTable") the `SLED`/`GLED`
   methods are stubs (`Function logic to be implemented!!!`), while
   `SLGO`/`GLGO` ("Customized Logo") go through SMI and refer to the BIOS boot
   logo, not the lid backlight.
2. There is a stock firmware WMI pair **`GLGS`/`SLGS`** (codes `0x0509`/`0x050A`),
   implemented as two EC registers:

   | Register | Meaning | Values |
   |---|---|---|
   | `0xA4` | state (GLGS) | `0x01` = off, `0x02` = on |
   | `0xA5` | set (SLGS) | `0x00` = off, `0x01` = on |

   Other values written to `0xA5` are ignored.
3. To reach the EC the firmware uses the method
   `\_SB.PC00.LPCB.HWEC.ECCD(cmd, off, len, data, retlen)` — a mailbox on ports
   `0x68` (data) / `0x6C` (status), `cmd=0x02` = EC RAM.
   Reply: `[status, length, data…]`, where `status=0` is success, `0x01` means
   no such register, `0x20` means the write was refused.
4. Secure Boot is enabled ⇒ the kernel is in `lockdown=integrity`, which
   forbids `ioperm`, `/dev/port`, `/dev/mem`, unsigned modules and "dangerous"
   module parameters (`ec_sys write_support=1` is likewise rejected). Access
   therefore goes through the firmware method `ECCD` from a signed DKMS module —
   Secure Boot is left untouched.

## State and boot

`0xA4`/`0xA5` are EC RAM, so the state may be reset on a full power removal
(check by rebooting; after a power cycle and after an EC reset it may return to
the default value). To guarantee the state after **every** boot:

```
sudo systemctl enable --now hwlogo-restore.service   # ExecStart=/usr/bin/hwlogo on
```

## Limitations

* Verified on a MateBook GT 14 (`ENZH-XX`), BIOS `1.16` (2025-07-22). Other
  MateBook models may use different addresses — check with
  `bash /usr/lib/hwlogo/hwec-call rd 0xa4` (needs `acpi-call-dkms`).
* Module parameters can be changed without a rebuild via `/etc/modprobe.d/`:
  `reg` (default `0xA5`), `state_reg` (`0xA4`), `on_value` (`0x01`),
  `off_value` (`0x00`).
* For reference, the other EC registers found on this model: `0x64`/`0x65` —
  keyboard backlight brightness (0/2/4), `0x6B`/`0x6C` — Fn-Lock (`0x55`/`0x5A`),
  `0x77` — microphone LED (`0x55`/`0x5A`), `0x7A`/`0x7B` — fan mode,
  `0x9C`/`0x9D` — keyboard backlight timeout.
