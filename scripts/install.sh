#!/bin/sh
# install.sh - build and install the hwlogo package, then verify it.
#
#   sudo ./scripts/install.sh --dry-run     # checks only (builds/installs nothing)
#   sudo ./scripts/install.sh               # build + apt install + verification
#   sudo ./scripts/install.sh --skip-build  # use the ready .deb from dist/
#   sudo ./scripts/install.sh --force       # allow installation on a different DMI model
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DRY=0; FORCE=0; SKIP=0
for a in "$@"; do
	case "$a" in
		--dry-run)    DRY=1 ;;
		--force)      FORCE=1 ;;
		--skip-build) SKIP=1 ;;
		*) echo "unknown option: $a (see the script header)" >&2; exit 2 ;;
	esac
done

say() { printf '%s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "need root: sudo $0"

# ---------- 1. is this the machine the driver was written for ----------
vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "?")
model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "?")
say "== machine: $vendor $model (kernel $(uname -r))"
case "$model" in
	ENZH-XX*) say "   model matches (ENZH-XX)" ;;
	*)
		say "   WARNING: the lid light was mapped on ENZH-XX (MateBook GT 14). It is just an EC"
		say "            register pair, so another MateBook may use different addresses - verify with"
		say "            the discovery tool (tools/find_logo.sh) before trusting this driver."
		[ "$FORCE" = 1 ] || die "run with --force if you really want to install here"
		;;
esac

# ---------- 2. what is missing ----------
missing=""
for t in dpkg-buildpackage dpkg-deb dkms modprobe; do
	command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
	say "== missing tools:$missing"
	say "   Ubuntu: sudo apt install dpkg-dev dkms kmod"
	[ "$DRY" = 1 ] || die "install the dependencies and retry"
fi

# the driver calls the firmware's own EC method; without ACPI there is nothing to call
[ -d /proc/acpi ] || die "/proc/acpi is missing - this driver needs ACPI (and the ECCD method)"

if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
	if grep -qs 'mok_signing_key' /etc/dkms/framework.conf; then
		say "== Secure Boot is on, MOK signing key configured in /etc/dkms/framework.conf ✓"
	else
		die "Secure Boot is on but /etc/dkms/framework.conf has no mok_signing_key: DKMS cannot sign the module and the kernel will refuse to load it (see docs/04-secureboot-mok.md in the matebook-gt-14-linux repo)"
	fi
fi

if [ "$DRY" = 1 ]; then
	say "== --dry-run: checks passed, nothing is built or installed"
	exit 0
fi

# ---------- 3. build ----------
if [ "$SKIP" = 1 ]; then
	ls "$ROOT"/dist/*.deb >/dev/null 2>&1 || die "--skip-build, but dist/ has no .deb yet"
	say "== --skip-build: using the ready package from dist/"
else
	say "== building the package"
	"$ROOT/build-deb.sh"
fi

# ---------- 4. install ----------
say "== installing the package"
apt-get install -y "$ROOT"/dist/hwlogo_*_all.deb

# ---------- 5. verify ----------
say "== verification"
hwlogo status || say "   hwlogo status failed"
if command -v hwlogo-healthcheck >/dev/null 2>&1; then
	hwlogo-healthcheck || say "   healthcheck reported a problem (see above)"
else
	say "   hwlogo-healthcheck not found"
fi

cat <<'EOT'

== What is left to do by hand

 1) GNOME Shell extension (the package installs it system-wide, enabling is per user):
      gnome-extensions enable hwlogo@fstronin
    On Wayland a newly installed extension only appears when the session starts - log out
    and back in once.  Then a "Logo light" tile shows up in the Quick Settings menu.

 2) Keep the light on after every boot (the state is EC RAM and may be reset):
      sudo systemctl enable --now hwlogo-restore.service

 3) No GNOME?  Bind a shortcut to "hwlogo toggle", or use the LED device directly:
      echo 1 > /sys/class/leds/huawei::logo/brightness

 Re-check any time:  hwlogo-healthcheck [--test]
EOT
