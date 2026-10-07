#!/bin/sh
# uninstall.sh - remove the hwlogo package (and point out what is left over).
#
#   sudo ./scripts/uninstall.sh            # remove, keep configs in /etc
#   sudo ./scripts/uninstall.sh --purge    # purge as well (drops /var/lib/dkms/hwlogo)
set -eu
[ "$(id -u)" = 0 ] || { echo "need root: sudo $0" >&2; exit 1; }

PURGE=""
[ "${1:-}" = "--purge" ] && PURGE="-p"

echo "== stopping and disabling the restore unit (if it was enabled)"
systemctl disable --now hwlogo-restore.service 2>/dev/null || true

echo "== removing the package"
apt-get remove -y $PURGE hwlogo || dpkg -r $([ -n "$PURGE" ] && echo --purge) hwlogo
if dpkg -l hwlogo 2>/dev/null | grep -E '^[a-z]{2}'; then
	echo "== still installed - check 'dkms status' and the prerm output above" >&2
fi

cat <<'EOT'

== Removed.  Leftovers you may want to clean up by hand

 * the GNOME extension is enabled per user:   gnome-extensions disable hwlogo@fstronin
 * module parameters, if you created any:     /etc/modprobe.d/*hwlogo*
 * acpi-call-dkms was only needed to find the EC registers in the first place:
       sudo apt purge acpi-call-dkms
 * the light state itself lives in the EC and is deliberately kept (the LED device
   sets LED_RETAIN_AT_SHUTDOWN, so uninstalling does not switch the logo off)
EOT
