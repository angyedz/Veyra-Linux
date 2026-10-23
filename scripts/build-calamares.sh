#!/bin/sh
# Compile and package Calamares against Alpine's Qt6/KF6 for Veyra.
# Runs in a disposable Alpine build container as root.
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Run as root' >&2; exit 1; }
[ -f /etc/alpine-release ] || { echo 'Requires Alpine Linux' >&2; exit 1; }
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
apk add --no-cache abuild build-base cmake ninja git go \
    extra-cmake-modules qt6-qtbase-dev qt6-qtdeclarative-dev \
    qt6-qtsvg-dev qt6-qttools-dev yaml-cpp-dev kcoreaddons-dev \
    kcrash-dev kconfig-dev ki18n-dev kwidgetsaddons-dev kservice-dev kpackage-dev kparts-dev kpmcore-dev polkit-qt-dev python3-dev py3-pybind11 \
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
'
# abuild must trust the signing key while updating its APK repository index.
cp /home/veyra-builder/.abuild/*.pub /etc/apk/keys/
su veyra-builder -s /bin/sh -c '
    set -eu
    cd /home/veyra-builder/aports/veyra-calamares
    abuild checksum
    abuild -r
'

# Build the atomic updater package from the pinned package-repository recipe.
# Its helper source comes from this Veyra-Linux checkout, keeping the binary,
# boot scripts and release manifest provenance in one ISO build.
update_source="${VEYRA_UPDATE_SOURCE:-}"
update_expected_revision=e8c5cf68325283eefe28bffb722a649995acd75b
if [ -z "$update_source" ] || [ ! -f "$update_source/src/veyra-update/APKBUILD" ]; then
    echo 'Missing checked-out Veyra updater package source.' >&2
    exit 1
fi
if [ -n "${VEYRA_UPDATE_REVISION:-}" ]; then
    update_actual_revision=$VEYRA_UPDATE_REVISION
else
    update_actual_revision=$(git -C "$update_source" rev-parse HEAD)
fi
[ "$update_actual_revision" = "$update_expected_revision" ] || {
    echo "Unexpected Veyra updater package source revision: $update_actual_revision" >&2
    exit 1
}
mkdir -p /home/veyra-builder/aports/veyra-update /home/veyra-builder/distro-source
cp -R "$update_source/src/veyra-update/." /home/veyra-builder/aports/veyra-update/
cp -R "$root/update" /home/veyra-builder/distro-source/
cp -R "$root/scripts" /home/veyra-builder/distro-source/
chown -R veyra-builder:veyra-builder \
    /home/veyra-builder/aports/veyra-update /home/veyra-builder/distro-source
su veyra-builder -s /bin/sh -c '
    set -eu
    cd /home/veyra-builder/aports/veyra-update
    abuild checksum
    abuild -r
'

# Include the AppCenter revision with passing source, package and QML CI.
# It is signed into this temporary development APK repository, not published
# as a stable Veyra package by the ISO workflow.
appcenter_source="${VEYRA_APPCENTER_SOURCE:-}"
appcenter_expected_revision=97dbd8b8df28e0e4fad66397473bfa2ff62d5532
if [ -z "$appcenter_source" ] || [ ! -f "$appcenter_source/src/veyra-appcenter/APKBUILD" ]; then
    echo 'Missing checked-out Veyra AppCenter package source.' >&2
    exit 1
fi
if [ -n "${VEYRA_APPCENTER_REVISION:-}" ]; then
    actual_revision=$VEYRA_APPCENTER_REVISION
else
    actual_revision=$(git -C "$appcenter_source" rev-parse HEAD)
fi
[ "$actual_revision" = "$appcenter_expected_revision" ] || {
    echo "Unexpected Veyra AppCenter source revision: $actual_revision" >&2
    exit 1
}
mkdir -p /home/veyra-builder/aports/veyra-appcenter
cp -R "$appcenter_source/src/veyra-appcenter/." /home/veyra-builder/aports/veyra-appcenter/
chown -R veyra-builder:veyra-builder /home/veyra-builder/aports/veyra-appcenter
su veyra-builder -s /bin/sh -c '
    set -eu
    cd /home/veyra-builder/aports/veyra-appcenter
    abuild checksum
    abuild -r
'

out="$root/dist/calamares"
mkdir -p "$out"
find /home/veyra-builder/packages -name '*.apk' -exec cp '{}' "$out/" ';'
cp /home/veyra-builder/.abuild/*.pub "$out/"
test -n "$(find "$out" -maxdepth 1 -name 'veyra-calamares-*.apk' -print -quit)"
test -n "$(find "$out" -maxdepth 1 -name 'veyra-appcenter-*.apk' -print -quit)"
test -n "$(find "$out" -maxdepth 1 -name 'veyra-update-*.apk' -print -quit)"
echo "Calamares, Veyra AppCenter and atomic updater APK artifacts in $out"
