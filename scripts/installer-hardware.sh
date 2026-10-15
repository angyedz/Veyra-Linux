#!/bin/sh
# Use LIVE CPU/PCI information to install native firmware and graphics packages
# on the target. Never uses third-party driver installers or edge repositories.
set -eu
target="${1:?missing target path}"
case "$target" in /|''|/tmp|/mnt|/run) echo "Invalid target" >&2; exit 1 ;; esac
[ -f "$target/etc/apk/world" ] || { echo 'Missing target Alpine install' >&2; exit 1; }
mountpoint -q "$target" || { echo 'Target is not mounted' >&2; exit 1; }

detector=/usr/local/lib/veyra/hardware-detect.sh
[ -r "$detector" ] || {
    detector=$(CDPATH='' cd "$(dirname "$0")" && pwd)/hardware-detect.sh
}

echo 'Detecting CPU and graphics hardware:'
sh "$detector" --report
packages=$(sh "$detector" --packages)
if [ -n "$packages" ]; then
    # The detector only emits audited, static Alpine package names.
    # shellcheck disable=SC2086
    set -- $packages
    echo "Installing detected hardware support: $*"
    chroot "$target" apk add --no-cache "$@" || {
        echo 'Hardware support installation failed. Check network and repositories.' >&2
        exit 1
    }
else
    echo 'No additional vendor-specific packages required.'
fi

# Alpine's diskless live image does not require a disk root filesystem
# driver. Once installed, the initramfs MUST include the actual filesystem
# chosen by Calamares and load it before attempting to mount /sysroot.
root_fs=$(findmnt -n -o FSTYPE -M "$target") || {
    echo 'Cannot determine the installed root filesystem type.' >&2
    exit 1
}
case "$root_fs" in
    ext4|btrfs|xfs|f2fs) ;;
    *) echo "Unsupported installed root filesystem: $root_fs" >&2; exit 1 ;;
esac

# Preserve Alpine's existing initramfs features; add the selected root
# filesystem as well as common disk controllers (NVMe and VirtIO).
initfs_config="$target/etc/mkinitfs/mkinitfs.conf"
mkdir -p "$target/etc/mkinitfs"
printf '\n# Required by Veyra for disk-based boot.\nfeatures="${features:-ata base scsi usb} %s virtio nvme"\n' "$root_fs" >> "$initfs_config"

# Alpine's initramfs loader only loads the root filesystem module early
# when rootfstype= is passed. Keep any prior GRUB kernel options intact.
mkdir -p "$target/etc/default"
printf '\n# Veyra: allow Alpine initramfs to mount the installed root.\nGRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:+${GRUB_CMDLINE_LINUX} }rootfstype=%s"\n' "$root_fs" >> "$target/etc/default/grub"
echo "Configured disk boot filesystem: $root_fs"

# Regenerate an initramfs for the INSTALLED kernel, not the live ISO's
# running uname -r. The kernel modules must have been unpacked to disk by
# installer-prepare.sh, and this includes newly installed firmware.
kernel_found=0
for modules in "$target"/lib/modules/*; do
    [ -d "$modules" ] || continue
    kernel_found=1
    version=${modules##*/}
    echo "Building initramfs for installed kernel $version"
    chroot "$target" mkinitfs "$version"
done
[ "$kernel_found" -eq 1 ] || {
    echo 'Cannot generate initramfs: missing installed kernel modules' >&2
    exit 1
}
mkdir -p "$target/var/log/veyra"
sh "$detector" --report > "$target/var/log/veyra/hardware-detected.txt"
printf '%s\n' "$packages" > "$target/var/log/veyra/hardware-packages.txt"
echo 'Hardware support installed.'
