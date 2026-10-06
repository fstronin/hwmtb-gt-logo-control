#!/bin/sh
# build-deb.sh - build the hwlogo package (DKMS module + CLI + udev rule).
#
# Only dpkg-dev is needed (dpkg-buildpackage / dpkg-gencontrol / dpkg-deb);
# debhelper is deliberately not used.  The version is taken from
# debian/changelog - to release a new version just add a changelog entry
# (dch -i) and rebuild.
set -eu
cd "$(dirname "$0")"

VERSION=$(dpkg-parsechangelog -S Version)
DEB="hwlogo_${VERSION}_all.deb"

command -v dpkg-buildpackage >/dev/null 2>&1 || {
	echo "dpkg-dev is required: sudo apt install dpkg-dev" >&2
	exit 1
}

dpkg-buildpackage --build=binary --no-check-builddeps -us -uc -tc

# .changes/.buildinfo are only needed to upload to an archive; keep $HOME clean
rm -f "../hwlogo_${VERSION}_amd64.changes" "../hwlogo_${VERSION}_amd64.buildinfo"

echo
echo "== built: $(dirname "$PWD")/$DEB =="
ls -l "../$DEB"
echo
echo "install:      sudo apt install ./$DEB"
echo "re-install:   sudo apt install --reinstall ./$DEB"
echo "remove:       sudo apt purge hwlogo"
echo "contents:     dpkg -L hwlogo"
