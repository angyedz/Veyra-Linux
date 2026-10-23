#!/bin/sh
# Real Linux mount namespace regression for Alpine's Veyra early-root hook.
# Operates ONLY on a disposable loopback ext4 filesystem.
set -eu
[ "$(id -u)" -eq 0 ] || exit 1
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
temp=$(mktemp -d /tmp/veyra-init-select.XXXXXX)
store="$temp/store"
sysroot="$temp/sysroot"
cleanup() {
    umount -R "$sysroot" 2>/dev/null || true
    umount "$store" 2>/dev/null || true
    rm -rf "$temp"
}
trap cleanup EXIT HUP INT TERM
truncate -s 384M "$temp/loop.img"
mkfs.ext4 -q -F "$temp/loop.img"
mkdir -p "$store" "$sysroot"
mount -o loop "$temp/loop.img" "$store"
sh "$root/scripts/veyra-deployment.sh" init "$store"
mkdir -p "$store/deployments/A/etc/apk" "$store/deployments/A/etc/veyra"
mkdir -p "$store/deployments/A/sbin" "$store/deployments/A/var/lib/veyra/user-root"
printf 'alpine-base\n' > "$store/deployments/A/etc/apk/world"
printf 'A\n' > "$store/deployments/A/etc/veyra/deployment-id"
printf '#!/bin/sh\nexit 0\n' > "$store/deployments/A/sbin/init"
chmod 0755 "$store/deployments/A/sbin/init"
mkdir -p "$store/user-environments/U-A/etc/apk" \
    "$store/user-environments/U-A/etc/veyra" "$store/user-environments/U-A/sbin"
printf 'alpine-base\n' > "$store/user-environments/U-A/etc/apk/world"
printf 'U-A\n' > "$store/deployments/A/etc/veyra/user-environment-id"
printf 'U-A\n' > "$store/user-environments/U-A/etc/veyra/user-environment-id"
printf '#!/bin/sh\nexit 0\n' > "$store/user-environments/U-A/sbin/init"
chmod 0755 "$store/user-environments/U-A/sbin/init"
printf 'shared user root content\n' > "$store/user-environments/U-A/etc/veyra/test-marker"
printf 'durable user file\n' > "$store/persistent/home/user.txt"

# No selection must never change the conventional root.
mount --bind "$store" "$sysroot"
sysroot="$sysroot" KOPT_veyra_deployment='' sh -c     '. "$1"' sh "$root/scripts/veyra-initramfs-select.sh"
test -f "$sysroot/.veyra-deployment-store"
umount "$sysroot"

# Missing and invalid slot IDs fail before any mount mutations.
mount --bind "$store" "$sysroot"
if sysroot="$sysroot" KOPT_veyra_deployment='../bad' sh -c     '. "$1"' sh "$root/scripts/veyra-initramfs-select.sh"; then
    echo 'Unsafe deployment ID was accepted' >&2
    exit 1
fi
test -f "$sysroot/.veyra-deployment-store"
umount "$sysroot"

# Reject a kernel-selected user root that does not match this system slot.
mount --bind "$store" "$sysroot"
if sysroot="$sysroot" KOPT_veyra_deployment='A' \
    KOPT_veyra_user_environment='U-WRONG' sh -c \
    '. "$1"' sh "$root/scripts/veyra-initramfs-select.sh"; then
    echo 'Mismatched user environment pair was accepted' >&2
    exit 1
fi
test -f "$sysroot/.veyra-deployment-store"
umount "$sysroot"

# Select A as the new real system root and move independent persistent state.
mount --bind "$store" "$sysroot"
sysroot="$sysroot" KOPT_veyra_deployment='A' KOPT_veyra_user_environment='U-A' \
    sh -c '. "$1"' sh "$root/scripts/veyra-initramfs-select.sh"
test "$(cat "$sysroot/etc/veyra/deployment-id")" = A
test "$(cat "$sysroot/home/user.txt")" = 'durable user file'
test -f "$sysroot/var/lib/veyra/store/.veyra-deployment-store"
test "$(cat "$sysroot/var/lib/veyra/store/deployments/A/etc/veyra/deployment-id")" = A
test "$(cat "$sysroot/var/lib/veyra/user-root/etc/veyra/test-marker")" = 'shared user root content'
test "$(cat "$sysroot/var/lib/veyra/user-root/etc/veyra/user-environment-id")" = U-A
test "$(findmnt -n -o SOURCE -M "$sysroot/var/lib/veyra/user-root" | wc -l)" -eq 1
test "$(findmnt -n -o SOURCE -M "$sysroot/home" | wc -l)" -eq 1
test -d "$sysroot/nix"
echo 'Real filesystem-neutral initramfs selector mount test passed'
