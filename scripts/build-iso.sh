#!/bin/sh
# Build an experimental Veyra Linux ISO on Alpine Linux (x86_64).
set -eu

[ -f /etc/alpine-release ] || {
    echo 'This build script requires an Alpine Linux host/container.' >&2
    exit 1
}
[ "$(uname -m)" = x86_64 ] || {
    echo 'ISO builds currently require x86_64.' >&2
    exit 1
}
[ "$(id -u)" -eq 0 ] || {
    echo 'Run as root in a disposable Alpine build container.' >&2
    exit 1
}

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
version="${VEYRA_ALPINE_VERSION:-3.22}"
case "$version" in
    3.[0-9]* ) ;;
    * ) echo 'Invalid VEYRA_ALPINE_VERSION' >&2; exit 1 ;;
esac

outdir="${VEYRA_OUTDIR:-$root/dist}"
buildroot="${VEYRA_BUILDROOT:-$root/.build}"
aports="$buildroot/aports"
workdir="$buildroot/mkimage"
mkdir -p "$outdir" "$buildroot"

apk add --no-cache abuild alpine-conf git fakeroot syslinux xorriso \
    squashfs-tools grub grub-efi mtools coreutils findutils

# Generate a temporary package index signing key for this development build.
if [ ! -f "$HOME/.abuild/abuild.conf" ]; then
    abuild-keygen -a -n
fi
# shellcheck disable=SC1090
. "$HOME/.abuild/abuild.conf"
: "${PACKAGER_PRIVKEY:?abuild-keygen must configure PACKAGER_PRIVKEY}"
export PACKAGER_PRIVKEY
cp "${PACKAGER_PRIVKEY}.pub" /etc/apk/keys/

if [ ! -f "$aports/scripts/mkimage.sh" ]; then
    git clone --depth 1 --branch "$version-stable" \
        https://github.com/alpinelinux/aports.git "$aports"
fi
cp "$root/images/mkimg.veyra.sh" "$aports/scripts/mkimg.veyra.sh"

# mkimage locates the apkovl generator relative to the current working dir.
chmod +x "$root/images/genapkovl-veyra.sh"
cd "$root"
sh "$aports/scripts/mkimage.sh" \
    --tag "$version-dev" \
    --profile veyra \
    --arch x86_64 \
    --outdir "$outdir" \
    --workdir "$workdir" \
    --checksum \
    --repository "https://dl-cdn.alpinelinux.org/alpine/v$version/main" \
    --repository "https://dl-cdn.alpinelinux.org/alpine/v$version/community"

echo "Experimental ISO and checksums: $outdir"
