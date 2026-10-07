#!/bin/sh
# build-deb.sh - build the hwlogo package (DKMS module + CLI + udev rule).
#
# Only dpkg-dev is needed (dpkg-buildpackage / dpkg-gencontrol / dpkg-deb);
# debhelper is deliberately not used.  The version is single-sourced from
# debian/changelog - to release a new version add a changelog entry (dch -i)
# and rebuild.  The .deb lands in dist/.
set -eu
cd "$(dirname "$0")"

VERSION=$(dpkg-parsechangelog -S Version)
DEB="dist/hwlogo_${VERSION}_all.deb"

command -v dpkg-buildpackage >/dev/null 2>&1 || {
	echo "dpkg-dev is required: sudo apt install dpkg-dev" >&2
	exit 1
}

mkdir -p dist
# dpkg-buildpackage drops the package next to the source tree; move it into dist/
dpkg-buildpackage --build=binary --no-check-builddeps -us -uc -tc
mv -f "../hwlogo_${VERSION}_all.deb" "$DEB"

# .changes/.buildinfo are only needed to upload to an archive; keep $HOME clean
rm -f "../hwlogo_${VERSION}_amd64.changes" "../hwlogo_${VERSION}_amd64.buildinfo"

echo
echo "== built: $PWD/$DEB =="
ls -l "$DEB"
echo
echo "install:       sudo ./scripts/install.sh --skip-build"
echo "manual:        sudo apt install ./$DEB"
echo "health check:  hwlogo-healthcheck   (in the installed package)"
echo "remove:        sudo ./scripts/uninstall.sh"
