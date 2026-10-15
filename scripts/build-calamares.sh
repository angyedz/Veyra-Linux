#!/bin/sh
# Compile and package Calamares against Alpine's Qt6/KF6 for Veyra.
# Runs in a disposable Alpine build container as root.
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Run as root' >&2; exit 1; }
[ -f /etc/alpine-release ] || { echo 'Requires Alpine Linux' >&2; exit 1; }
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
apk add --no-cache abuild build-base cmake ninja git \
    extra-cmake-modules qt6-qtbase-dev qt6-qtdeclarative-dev \
    qt6-qtsvg-dev qt6-qttools-dev yaml-cpp-dev kcoreaddons-dev \
    kcrash-dev kpmcore-dev python3-dev py3-pybind11 \
    py3-yaml parted rsync grub efibootmgr util-linux

if ! id -u veyra-builder >/dev/null 2>&1; then
    adduser -D -h /home/veyra-builder -s /bin/ash veyra-builder
fi
mkdir -p /home/veyra-builder/aports/veyra-calamares /home/veyra-builder/.abuild
cp "$root/packaging/calamares/APKBUILD" /home/veyra-builder/aports/veyra-calamares/
chown -R veyra-builder:veyra-builder /home/veyra-builder
addgroup veyra-builder abuild 2>/dev/null || true

su veyra-builder -s /bin/sh -c '
    set -eu
    cd /home/veyra-builder/aports/veyra-calamares
    abuild-keygen -a -n
    abuild checksum
    abuild -r
'
out="$root/dist/calamares"
mkdir -p "$out"
find /home/veyra-builder/packages -name '*.apk' -exec cp '{}' "$out/" ';'
cp /home/veyra-builder/.abuild/*.pub "$out/"
test -n "$(find "$out" -name '*.apk' -print -quit)"
echo "Calamares APK artifacts in $out"
