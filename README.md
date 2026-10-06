# hwmtb-gt-logo-control

Linux control for the illuminated **HUAWEI** wordmark on the lid of the
**HUAWEI MateBook GT 14**.

Ships as a Debian/Ubuntu package: a DKMS kernel module, a `hwlogo(1)` CLI and a
standard LED class device (`/sys/class/leds/huawei::logo`).  No Windows, no
HUAWEI PC Manager, and **Secure Boot can stay enabled**.

```
$ hwlogo on
$ hwlogo status
Logo light: on (brightness=255)
EC[0xa4]=0x02
```

## Status / tested hardware

| | |
|---|---|
| Laptop | HUAWEI MateBook GT 14, model `ENZH-XX`, board `ENZH-XX-PCB` |
| BIOS | Insyde `1.16` (2025-07-22) |
| Embedded controller | Microchip MEC1930 class |
| OS | Ubuntu 26.04, kernel `7.0.0-30-generic` |
| Secure Boot | enabled, kernel `lockdown=integrity` (the module is MOK-signed) |

Other MateBook generations very likely use the same EC register pair; verify
before trusting it (`/usr/lib/hwlogo/hwec-call rd 0xa4`).
Russian notes about the discovery process: [`docs/README.ru.md`](docs/README.ru.md).

## Why this is not a five-line shell script

* The lid logo is driven by the **embedded controller (EC)**, not by the GPU,
  the panel backlight or the keyboard backlight controller.
* This BIOS exposes **no ACPI/WMI command** for the light.  In HUAWEI's
  `SSDT18` ("HUAWEI WmiTable") the `SLED`/`GLED` methods are stubs
  (`Function logic to be implemented!!!`), and `SLGO`/`GLGO`
  ("Customized Logo") go through an SMI to program the **boot logo**, not the
  lid light.
* What *is* implemented is the WMI command pair **GLGS/SLGS**
  (command bytes `0x0509`/`0x050A`, group 5 "setup settings"), which is a thin
  wrapper around two EC registers:

  | EC register | Purpose | Values |
  |---|---|---|
  | `0xA4` | state (GLGS) | `0x01` = off, `0x02` = on |
  | `0xA5` | control (SLGS) | `0x00` = off, `0x01` = on |

  Any other value written to `0xA5` is ignored by the EC.
* Userspace cannot poke the EC directly here: with Secure Boot enabled the
  kernel runs in `lockdown=integrity`, which refuses `ioperm`/`iopl`,
  `/dev/port`, `/dev/mem`, unsigned modules and "unsafe" module parameters
  (`ec_sys write_support=1` is rejected as well).
* Therefore the driver calls the firmware's own EC access method
  `\_SB.PC00.LPCB.HWEC.ECCD()` through `acpi_evaluate_object()`, which keeps
  the firmware's EC mutex, retries and timeouts in charge, and DKMS signs the
  built module with the machine's enrolled MOK key.

## EC interface (for porting to other models)

`ECCD(cmd, offset, length, data, reply_len)` is a mailbox on non-standard ports:

```
ports:   0x68 = data, 0x6C = status   (bit 0 = OBF: EC wrote a byte,
                                       bit 1 = IBF: host byte not consumed)
cmd 0x02 = EC RAM access
cmd 0x03 = EC sampling information, cmd 0x04 = fan test/set speed
sequence: 0x6C <- cmd, 0x6C <- offset, 0x6C <- length
          (wait for IBF clear before each byte)
          0x68 <- data bytes (length of them, wait for IBF clear)
          read reply from 0x68 while OBF is set
reply:    [status, length, data...]
          status 0x00 = ok, 0x01 = register not implemented,
          0x20 = write refused (read-only register)
```

Registers found on the MateBook GT 14 (useful when porting):

| EC | Meaning |
|---|---|
| `0x64` / `0x65` | keyboard backlight level (read) / set (0/2/4) |
| `0x6B` / `0x6C` | Fn-lock state / set (`0x55` = off, `0x5A` = on) |
| `0x77` | microphone LED (`0x55` = off, `0x5A` = on, write-only) |
| `0x7A` / `0x7B` | fan mode set / read |
| `0x9C` / `0x9D` | keyboard backlight idle timeout (read / set) |
| `0xA4` / `0xA5` | **lid logo light state / control** |

## Build

Requirements: `dpkg-dev` (nothing else — `debian/rules` is hand written, no
debhelper).  The kernel module itself is compiled **on the target machine** by
DKMS, so the build host needs no kernel headers.

```sh
git clone git@github.com:fstronin/hwmtb-gt-logo-control.git
cd hwmtb-gt-logo-control
./build-deb.sh                 # -> ../hwlogo_<version>_all.deb
```

The version is single-sourced from `debian/changelog` and substituted into
`dkms.conf` and the maintainer scripts at build time — to release a new
version, add a changelog entry (`dch -i`) and rebuild:

```sh
sudo apt install --reinstall ./hwlogo_<new-version>_all.deb
```

Manual (non-packaged) install, if you prefer:

```sh
sudo install -d /usr/src/hwlogo-1.0.2
sudo install -m 0644 src/hwlogo.c src/Makefile /usr/src/hwlogo-1.0.2/
sed 's/@VERSION@/1.0.2/' src/dkms.conf.in | sudo tee /usr/src/hwlogo-1.0.2/dkms.conf
sudo dkms add -m hwlogo -v 1.0.2 && sudo dkms build -m hwlogo -v 1.0.2 \
     && sudo dkms install -m hwlogo -v 1.0.2
sudo cp src/90-hwlogo.rules /usr/lib/udev/rules.d/ && sudo udevadm control --reload-rules
sudo modprobe hwlogo
```

## Install and use

```sh
sudo apt install ./hwlogo_<version>_all.deb
```

| Path | Purpose |
|---|---|
| `/usr/src/hwlogo-<ver>/{hwlogo.c,Makefile,dkms.conf}` | module sources for DKMS |
| `/usr/bin/hwlogo` | CLI: `on`, `off`, `toggle`, `status` |
| `/sys/class/leds/huawei::logo/{brightness,ec}` | standard LED interface |
| `/usr/lib/udev/rules.d/90-hwlogo.rules` | grants group `plugdev` write access to `brightness` |
| `/etc/modules-load.d/hwlogo.conf` | loads the module at boot |
| `/usr/lib/systemd/system/hwlogo-restore.service` | optional: re-apply the state at boot |
| `/usr/lib/hwlogo/{hwec-call,find_logo.sh}` | debugging/re-discovery tools (need `acpi-call-dkms`) |
| `/usr/share/doc/hwlogo/README.md` | this file |

Usage:

```sh
hwlogo on | off | toggle | status          # no sudo needed
echo 1 > /sys/class/leds/huawei::logo/brightness
cat /sys/class/leds/huawei::logo/ec        # raw EC state register
```

Notes:

* The state lives in the EC, so it is **not** clobbered by module unload,
  package upgrade or purge (the LED class device sets `LED_RETAIN_AT_SHUTDOWN`;
  otherwise the LED core switches the light off in
  `led_classdev_unregister()`).
* It is EC RAM: a full power loss / EC reset may return the light to its
  default.  Enable the systemd unit if you want the state enforced at boot:
  `sudo systemctl enable --now hwlogo-restore.service`.
* Module parameters (no rebuild needed, via `/etc/modprobe.d/`): `reg`
  (`0xA5`), `state_reg` (`0xA4`), `on_value` (`0x01`), `off_value` (`0x00`).

## Uninstall

```sh
sudo apt purge hwlogo
```

## Troubleshooting

```sh
dkms status | grep hwlogo                    # built for which kernels
modinfo -F signer /lib/modules/$(uname -r)/updates/dkms/hwlogo.ko*   # should print a key name
lsmod | grep hwlogo
dmesg | grep -i hwlogo                       # driver messages
```

* **No `/sys/class/leds/huawei::logo`** — the module is not loaded.  With
  Secure Boot enabled and no enrolled MOK key the module cannot be loaded at
  all (DKMS signs it with `/var/lib/shim-signed/mok/MOK.priv` when that key
  exists; otherwise enroll one with `mokutil --import` and reboot, or disable
  Secure Boot).
* **Module loads but the light does not react** — check the EC state directly
  (needs `acpi-call-dkms`):

  ```sh
  echo '\_SB.PC00.LPCB.HWEC.ECCD 0x02 0xa4 0x00 {0x00} 0x100' > /proc/acpi/call
  cat /proc/acpi/call
  ```

  `0x01` = off, `0x02` = on.  If `ECCD` does not exist on your model, the
  register pair has to be re-discovered with `tools/find_logo.sh`.
* **Wrong keyboard/other side effects** — none expected: the driver touches
  only `0xA5` (write) and `0xA4` (read).

## Reverse engineering summary

1. `acpidump` + `iasl` → `DSDT` and 28 SSDTs; `SSDT18` ("HUAWEI WmiTable") holds
   the vendor WMI dispatch with `ADBG("wmiGGCC: ...")` annotations naming the
   subsystem each command belongs to.
2. Command group 5 (`0x0501`–`0x050A`) is "get/set setup setting"; commands
   `0x0509`/`0x050A` (`GLGS`/`SLGS`) touch EC `0xA4`/`0xA5`.
3. Registers were probed through `acpi-call-dkms` (DKMS-signed, so it loads
   despite Secure Boot): read scan for implemented registers, write scan for
   writable ones, then a batched search for the one that lights the logo.
4. Shipped as a DKMS module behind a standard LED class device so the light can
   be driven by any LED-aware tooling, not only by this CLI.

## License

GPL-2.0 (see [`LICENSE`](LICENSE)) — it is a kernel module and links against
GPL-only symbols.

This is reverse engineered, unofficial software: no warranty, use at your own
risk.  The EC also drives power, thermal and charging logic on this laptop —
do not extend the register poking blindly.
