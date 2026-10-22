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

root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
version="${VEYRA_ALPINE_VERSION:-3.22}"
case "$version" in
    3.[0-9]* ) ;;
    * ) echo 'Invalid VEYRA_ALPINE_VERSION' >&2; exit 1 ;;
esac

veyra_release_version="${VEYRA_VERSION:-0.1.0-alpha.1+local}"
case "$veyra_release_version" in
    ''|*[!A-Za-z0-9.+-]*)
        echo 'Invalid VEYRA_VERSION; use only letters, digits, dots, plus and hyphens.' >&2
        exit 1
        ;;
esac
export VEYRA_VERSION="$veyra_release_version"

outdir="${VEYRA_OUTDIR:-$root/dist}"
buildroot="${VEYRA_BUILDROOT:-$root/.build}"
mkdir -p "$outdir" "$buildroot"
buildroot=$(CDPATH='' cd "$buildroot" && pwd)
aports="$buildroot/aports"
workdir="$buildroot/mkimage"

apk add --no-cache abuild alpine-conf git fakeroot syslinux xorriso \
    squashfs-tools grub grub-efi mtools coreutils findutils

# Generate a temporary package index signing key for this development build.
if [ ! -f "$HOME/.abuild/abuild.conf" ]; then
    abuild-keygen -a -n
fi
# shellcheck disable=SC1090,SC1091
. "$HOME/.abuild/abuild.conf"
: "${PACKAGER_PRIVKEY:?abuild-keygen must configure PACKAGER_PRIVKEY}"
export PACKAGER_PRIVKEY
cp "${PACKAGER_PRIVKEY}.pub" /etc/apk/keys/

# Build a signed, local APK repository from the Calamares build artifact.
extra_dir="${VEYRA_EXTRA_APK_DIR:-$root/dist/calamares}"
repo_base="$buildroot/veyra-repository"
repo_arch="$repo_base/x86_64"
temporary_apk_keys="$buildroot/temporary-apk-keys.txt"
mkdir -p "$repo_arch"
if [ ! -d "$extra_dir" ] || \
    [ -z "$(find "$extra_dir" -maxdepth 1 -name 'veyra-calamares-*.apk' -print -quit)" ] || \
    [ -z "$(find "$extra_dir" -maxdepth 1 -name 'veyra-appcenter-*.apk' -print -quit)" ]; then
    echo 'Missing Calamares or Veyra AppCenter APK. Run scripts/build-calamares.sh first.' >&2
    exit 1
fi
cp "$extra_dir"/*.apk "$repo_arch/"
: > "$temporary_apk_keys"
for key in "$extra_dir"/*.pub; do
    [ -f "$key" ] || continue
    cp "$key" /etc/apk/keys/
    basename "$key" >> "$temporary_apk_keys"
done
[ -s "$temporary_apk_keys" ] || {
    echo 'Missing public key for the temporary desktop APK repository.' >&2
    exit 1
}
basename "${PACKAGER_PRIVKEY}.pub" >> "$temporary_apk_keys"
LC_ALL=C sort -u "$temporary_apk_keys" > "$temporary_apk_keys.sorted"
mv "$temporary_apk_keys.sorted" "$temporary_apk_keys"
apk index -o "$repo_arch/APKINDEX.tar.gz" "$repo_arch"/*.apk
abuild-sign "$repo_arch/APKINDEX.tar.gz"

if [ ! -f "$aports/scripts/mkimage.sh" ]; then
    git clone --depth 1 --branch "$version-stable" \
        https://github.com/alpinelinux/aports.git "$aports"
fi
cp "$root/images/mkimg.veyra.sh" "$aports/scripts/mkimg.veyra.sh"

# mkimage locates the apkovl generator relative to the current working dir.
chmod +x "$root/images/genapkovl-veyra.sh"
cd "$root"
export VEYRA_TEMP_APK_KEYS_MANIFEST="$temporary_apk_keys"
sh "$aports/scripts/mkimage.sh" \
    --tag "$version-dev" \
    --profile veyra \
    --arch x86_64 \
    --outdir "$outdir" \
    --workdir "$workdir" \
    --checksum \
    --hostkeys \
    --repository "file://$repo_base" \
    --repository "https://dl-cdn.alpinelinux.org/alpine/v$version/main" \
    --repository "https://dl-cdn.alpinelinux.org/alpine/v$version/community"

echo "Experimental ISO and checksums: $outdir"
