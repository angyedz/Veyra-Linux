#!/bin/sh
# Destructive operations apply ONLY to a fresh ephemeral loopback image.
# Exercise the SAME deployment staging on ext4 and XFS when available.
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Requires root in disposable CI VM' >&2; exit 1; }
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d /tmp/veyra-fs-ci.XXXXXX)
top="$tmp/top"
cleanup() {
    if mountpoint -q "$top" 2>/dev/null; then umount "$top"; fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$top"
for fs in ext4 xfs; do
    case "$fs" in
        ext4) formatter='mkfs.ext4 -F' ;;
        xfs) formatter='mkfs.xfs -f' ;;
    esac
    image="$tmp/$fs.img"
    truncate -s 512M "$image"
    $formatter "$image" >/dev/null
    mount -o loop "$image" "$top"
    sh "$root/scripts/veyra-deployment.sh" init "$top"
    mkdir -p "$top/deployments/A/etc/veyra" "$top/deployments/A/etc/apk" \
        "$top/deployments/A/var/lib/veyra/user-root"
    printf 'A\n' > "$top/deployments/A/etc/veyra/deployment-id"
    printf 'alpine-base\nplasma-desktop\nkwin\n' > "$top/deployments/A/etc/apk/world"
    # Unit fixture: each deployment has its own kernel/initramfs and can be
    # selected by GRUB. These are NOT kernel images; QEMU boot tests are separate.
    mkdir -p "$top/deployments/A/boot" "$top/boot/grub"
    printf 'A kernel fixture\n' > "$top/deployments/A/boot/vmlinuz-lts"
    printf 'A initramfs fixture\n' > "$top/deployments/A/boot/initramfs-lts"
    mkdir -p "$top/user-environments/U-A/etc/apk" \
        "$top/user-environments/U-A/etc/veyra" "$top/user-environments/U-A/sbin" \
        "$top/user-environments/U-A/home" "$top/user-environments/U-A/nix"
    printf 'U-A\n' > "$top/deployments/A/etc/veyra/user-environment-id"
    printf 'alpine-base\nvpkg\n' > "$top/user-environments/U-A/etc/apk/world"
    printf 'U-A\n' > "$top/user-environments/U-A/etc/veyra/user-environment-id"
    printf '#!/bin/sh\nexit 0\n' > "$top/user-environments/U-A/sbin/init"
    chmod 0755 "$top/user-environments/U-A/sbin/init"
    printf 'must stay out of new root\n' > "$top/user-environments/U-A/home/private.txt"
    printf 'must stay out of new root\n' > "$top/user-environments/U-A/nix/private.txt"
    printf 'home unchanged\n' > "$top/persistent/home/user.txt"
    printf 'nix unchanged\n' > "$top/persistent/nix/profile.txt"
    sh "$root/scripts/veyra-deployment.sh" verify "$top" A
    sh "$root/scripts/veyra-deployment.sh" stage "$top" A B
    for runtime_dir in dev proc sys run tmp media mnt; do
        test -d "$top/deployments/B/$runtime_dir" || {
            echo "Missing staged runtime directory: $runtime_dir" >&2; exit 1;
        }
    done
    test "$(stat -c %a "$top/deployments/B/tmp")" = 1777
    sh "$root/scripts/veyra-deployment.sh" verify "$top" B
    grub-editenv "$top/boot/grub/grubenv" create
    grub-editenv "$top/boot/grub/grubenv" set saved_entry=veyra-A
    uuid=$(blkid -s UUID -o value "$image")
    python3 "$root/scripts/veyra-bootctl.py" --store "$top" init \
        --uuid "$uuid" --fstype "$fs" --default A
    python3 "$root/scripts/veyra-bootctl.py" --store "$top" status
    grep -q "veyra_deployment=A" "$top/boot/grub/grub.cfg"
    grep -q "veyra_deployment=B" "$top/boot/grub/grub.cfg"
    grep -q "veyra_user_environment=U-A" "$top/boot/grub/grub.cfg"
    grep -q "rootfstype=$fs" "$top/boot/grub/grub.cfg"
    grub-script-check "$top/boot/grub/grub.cfg"
    boot_cfg_before_pair=$(cat "$top/boot/grub/grub.cfg")
    grubenv_before_pair=$(grub-editenv "$top/boot/grub/grubenv" list)
    sh "$root/scripts/veyra-deployment.sh" stage-pair "$top" A C U-A U-C
    sh "$root/scripts/veyra-deployment.sh" verify-pair "$top" C U-C
    test "$(cat "$top/boot/grub/grub.cfg")" = "$boot_cfg_before_pair"
    test "$(grub-editenv "$top/boot/grub/grubenv" list)" = "$grubenv_before_pair"
    if grep -q 'veyra_deployment=C' "$top/boot/grub/grub.cfg"; then
        echo 'Pair staging changed GRUB before explicit activation' >&2
        exit 1
    fi
    test "$(cat "$top/deployments/C/etc/veyra/user-environment-id")" = U-C
    test "$(cat "$top/user-environments/U-C/etc/veyra/user-environment-id")" = U-C
    test "$(cat "$top/user-environments/U-C/etc/apk/world")" = "$(cat "$top/user-environments/U-A/etc/apk/world")"
    test ! -e "$top/user-environments/U-C/home/private.txt"
    test ! -e "$top/user-environments/U-C/nix/private.txt"
    test -d "$top/user-environments/U-C/home"
    test -d "$top/user-environments/U-C/nix"
    sh "$root/scripts/veyra-deployment.sh" stage-pair "$top" A C U-A U-C && {
        echo 'Overwrote an existing paired generation' >&2; exit 1;
    }
    mkdir -p "$top/user-environments/U-OTHER/etc/apk" \
        "$top/user-environments/U-OTHER/etc/veyra" "$top/user-environments/U-OTHER/sbin"
    printf 'alpine-base\n' > "$top/user-environments/U-OTHER/etc/apk/world"
    printf 'U-OTHER\n' > "$top/user-environments/U-OTHER/etc/veyra/user-environment-id"
    printf '#!/bin/sh\nexit 0\n' > "$top/user-environments/U-OTHER/sbin/init"
    chmod 0755 "$top/user-environments/U-OTHER/sbin/init"
    if sh "$root/scripts/veyra-deployment.sh" stage-pair "$top" A D U-OTHER U-D; then
        echo 'Staged a user root that did not match the source system pair' >&2
        exit 1
    fi
    test ! -e "$top/deployments/D"
    test ! -e "$top/user-environments/U-D"
    grub-editenv "$top/boot/grub/grubenv" list | grep -Fqx 'saved_entry=veyra-A'
    grub-script-check "$top/boot/grub/grub.cfg"
    python3 "$root/scripts/veyra-bootctl.py" --store "$top" activate B
    grep -q "veyra_deployment=C" "$top/boot/grub/grub.cfg"
    grep -q "veyra_user_environment=U-A" "$top/boot/grub/grub.cfg"
    grep -q "veyra_user_environment=U-C" "$top/boot/grub/grub.cfg"
    grub-editenv "$top/boot/grub/grubenv" list | grep -Fqx 'saved_entry=veyra-A'
    grub-editenv "$top/boot/grub/grubenv" list | grep -Fqx 'next_entry=veyra-B'
    grep -qx '# VEYRA_DEFAULT=A' "$top/boot/grub/grub.cfg"
    grep -q "^set default='veyra-A'$" "$top/boot/grub/grub.cfg"
    python3 "$root/scripts/veyra-bootctl.py" --store "$top" rollback A
    if grub-editenv "$top/boot/grub/grubenv" list | grep -q '^next_entry='; then
        echo 'Rollback did not clear the one-time trial' >&2; exit 1
    fi
    grub-editenv "$top/boot/grub/grubenv" list | grep -Fqx 'saved_entry=veyra-A'
    grep -q "^set default='veyra-A'$" "$top/boot/grub/grub.cfg"
    python3 "$root/scripts/veyra-bootctl.py" --store "$top" activate C
    grub-editenv "$top/boot/grub/grubenv" list | grep -Fqx 'next_entry=veyra-C'
    grep -q "veyra_deployment=C veyra_user_environment=U-C" "$top/boot/grub/grub.cfg"
    python3 "$root/scripts/veyra-bootctl.py" --store "$top" rollback A
    if python3 "$root/scripts/veyra-bootctl.py" --store "$top" activate '../evil'; then
        echo 'bootctl accepted traversal ID' >&2; exit 1
    fi
    if python3 "$root/scripts/veyra-bootctl.py" --store "$top" activate absent; then
        echo 'bootctl accepted missing root' >&2; exit 1
    fi
    grub-script-check "$top/boot/grub/grub.cfg"
    grep -qx kwin "$top/deployments/B/etc/apk/world"
    printf 'only in B\n' >> "$top/deployments/B/etc/apk/world"
    if grep -q 'only in B' "$top/deployments/A/etc/apk/world"; then
        echo 'System deployments share mutable world db!' >&2; exit 1
    fi
    test "$(cat "$top/persistent/home/user.txt")" = 'home unchanged'
    test "$(cat "$top/persistent/nix/profile.txt")" = 'nix unchanged'
    mv "$top/user-environments" "$top/user-environments.saved"
    ln -s "$tmp" "$top/user-environments"
    if sh "$root/scripts/veyra-deployment.sh" verify-pair "$top" C U-C; then
        echo 'Followed a symlinked user environment parent' >&2; exit 1
    fi
    rm "$top/user-environments"
    mv "$top/user-environments.saved" "$top/user-environments"
    mv "$top/deployments" "$top/deployments.saved"
    ln -s "$tmp" "$top/deployments"
    if sh "$root/scripts/veyra-deployment.sh" verify "$top" A; then
        echo 'Followed a symlinked system deployment parent' >&2; exit 1
    fi
    rm "$top/deployments"
    mv "$top/deployments.saved" "$top/deployments"
    if sh "$root/scripts/veyra-deployment.sh" stage "$top" A B; then
        echo 'Overwrote an existing deployment' >&2; exit 1
    fi
    if sh "$root/scripts/veyra-deployment.sh" stage "$top" A '../evil'; then
        echo 'Accepted traversal deployment ID' >&2; exit 1
    fi
    ln -s "$tmp" "$top/deployments/foreign"
    if sh "$root/scripts/veyra-deployment.sh" verify "$top" foreign; then
        echo 'Accepted symlink deployment' >&2; exit 1
    fi
    umount "$top"
    rm -f "$image"
done
if sh "$root/scripts/veyra-deployment.sh" init /; then
    echo 'Accepted live root as deployment store' >&2; exit 1
fi
echo 'Filesystem-neutral Veyra staging passed ext4 and XFS'
