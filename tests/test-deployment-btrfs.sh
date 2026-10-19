#!/bin/sh
# CI-only: exercise A/B system staging in a disposable loop-backed Btrfs.
# NEVER pass a real block device; the image is freshly created here.
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Btrfs test requires root' >&2; exit 1; }
command -v mkfs.btrfs >/dev/null
command -v btrfs >/dev/null
command -v mountpoint >/dev/null
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
temp=$(mktemp -d /tmp/veyra-btrfs-ci.XXXXXX)
top="$temp/top"
cleanup() {
    if mountpoint -q "$top" 2>/dev/null; then umount "$top"; fi
    rm -rf "$temp"
}
trap cleanup EXIT HUP INT TERM
truncate -s 512M "$temp/disposable.img"
mkfs.btrfs -q -f "$temp/disposable.img"
mkdir -p "$top"
mount -o loop,subvolid=5 "$temp/disposable.img" "$top"
sh "$root/scripts/veyra-deployment.sh" init "$top"
btrfs subvolume create "$top/@deploy-veyra-A"
mkdir -p "$top/@deploy-veyra-A/etc/veyra" "$top/@deploy-veyra-A/etc/apk"
printf 'veyra-A\n' > "$top/@deploy-veyra-A/etc/veyra/deployment-id"
printf 'alpine-base\nplasma-desktop\nkwin\n' > "$top/@deploy-veyra-A/etc/apk/world"
sh "$root/scripts/veyra-deployment.sh" verify "$top" veyra-A
sh "$root/scripts/veyra-deployment.sh" stage "$top" veyra-A veyra-B
test "$(cat "$top/@deploy-veyra-A/etc/veyra/deployment-id")" = veyra-A
test "$(cat "$top/@deploy-veyra-B/etc/veyra/deployment-id")" = veyra-B
grep -qx kwin "$top/@deploy-veyra-B/etc/apk/world"

# A and B have independent writable copy-on-write files and APK databases.
printf 'new-kde-generation\n' >> "$top/@deploy-veyra-B/etc/apk/world"
if grep -qx new-kde-generation "$top/@deploy-veyra-A/etc/apk/world"; then
    echo 'A/B roots unexpectedly share the mutable APK world database' >&2
    exit 1
fi
if sh "$root/scripts/veyra-deployment.sh" stage "$top" veyra-A veyra-B; then
    echo 'Overwrote an existing Veyra deployment' >&2
    exit 1
fi
if sh "$root/scripts/veyra-deployment.sh" stage "$top" veyra-A '../evil'; then
    echo 'Accepted invalid deployment path' >&2
    exit 1
fi
if sh "$root/scripts/veyra-deployment.sh" init /; then
    echo 'Allowed deployment init on live root' >&2
    exit 1
fi
ln -s "$temp/foreign" "$top/@deploy-foreign"
if sh "$root/scripts/veyra-deployment.sh" verify "$top" foreign; then
    echo 'Accepted symlinked deployment source' >&2
    exit 1
fi
# No action should touch this host: the loopback image is discarded on exit.
echo 'Veyra A/B Btrfs snapshot, independent APK database and safety tests passed'
