#!/bin/sh
# Opt-in conversion of a COMPLETED, OFFLINE conventional Alpine installation
# into Veyra filesystem-neutral A/B structure. For disposable QEMU guests
# until the full installer/bootloader and package-upgrade workflows are proven.
# Does NOT format any disk, requires the target root to be separately mounted.
# The original root and its GRUB config remain as a legacy recovery option.
# shellcheck disable=SC2015
set -eu
die() { echo "veyra-atomic-convert: $*" >&2; exit 1; }
[ "$#" -eq 1 ] || die 'usage: veyra-atomic-convert.sh /mounted/installed-root'
[ "$(id -u)" -eq 0 ] || die 'requires root'
store=$1
case "$store" in
    /*) : ;;
    *) die 'root mount must be absolute' ;;
esac
[ "$store" != / ] || die 'refusing running root'
mountpoint -q "$store" || die 'root must be mounted separately (offline)'
[ ! -L "$store" ] || die 'refusing symlink store'
for req in etc/apk/world boot/vmlinuz-lts boot/initramfs-lts boot/grub/grub.cfg; do
    [ -f "$store/$req" ] && [ ! -L "$store/$req" ] ||
        die "incomplete conventional Alpine root: $req"
done
# Alpine/OpenRC commonly uses /sbin/init -> /bin/busybox. A symlink is
# expected and must not be rejected by the regular-file preflight.
# -x checks that it resolves to a runnable init inside the mounted root.
[ -x "$store/sbin/init" ] ||
    die 'incomplete conventional Alpine root: executable sbin/init'
[ ! -e "$store/.veyra-deployment-store" ] ||
    die 'target already has deployment store; refusing partial conversion'
command -v python3 >/dev/null || die 'requires Python 3 for boot transaction metadata'
command -v mkinitfs >/dev/null || die 'requires installed Alpine mkinitfs'
command -v rsync >/dev/null || die 'requires rsync'
command -v blkid >/dev/null || die 'requires blkid'
scriptdir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
filesystem=$(findmnt -n -o FSTYPE -M "$store") || die 'cannot identify root filesystem'
case "$filesystem" in ext4|xfs|f2fs|btrfs) : ;; *) die "unsupported filesystem: $filesystem";; esac
device=$(findmnt -n -o SOURCE -M "$store") || die 'cannot identify root device'
uuid=$(blkid -s UUID -o value "$device") || die 'cannot identify root filesystem UUID'
[ -n "$uuid" ] || die 'missing UUID'

sh "$scriptdir/veyra-deployment.sh" init "$store"
root="$store/deployments/A"
mkdir -p "$root"
# Never copy child mounts, generated deployment trees, /proc, or user data
# into the bootable generation. Kernel+initramfs belong to this generation;
# physical /boot/grub is managed separately for all generations.
rsync -aHAX --numeric-ids --one-file-system \
    --exclude='/deployments/***' --exclude='/persistent/***' \
    --exclude='/boot-state/***' --exclude='/.veyra-deployment-store' \
    --exclude='/boot/grub/***' \
    --exclude='/home/***' --exclude='/nix/***' \
    --exclude='/dev/***' --exclude='/proc/***' \
    --exclude='/sys/***' --exclude='/run/***' \
    --exclude='/tmp/***' --exclude='/media/***' \
    --exclude='/mnt/***' \
    "$store/" "$root/" || die 'failed to copy installed system to A'

# Durable user data will be mounted separately by initramfs. Never roll back
# these data with the OS. User's FS selection is unchanged throughout.
for path in home nix; do
    [ ! -L "$store/$path" ] || die "symlinked user state: $path"
    if [ -d "$store/$path" ]; then
        rsync -aHAX --numeric-ids --one-file-system \
            "$store/$path/" "$store/persistent/$path/" ||
            die "failed to preserve persistent $path"
    fi
done

mkdir -p "$root/etc/veyra" "$root/usr/local/lib/veyra" "$root/usr/local/sbin" \
    "$root/home" "$root/nix" "$root/var/lib/veyra/shared" "$root/var/lib/veyra/store"
# --exclude=/run/*** and similar rsync filters remove the directories as
# well as volatile contents. OpenRC requires a real /run before boot.
# Every generation must provide empty Linux mountpoint placeholders.
for runtime_dir in dev proc sys run tmp media mnt; do
    [ ! -L "$root/$runtime_dir" ] || die "symlinked runtime mountpoint: $runtime_dir"
    mkdir -p "$root/$runtime_dir"
done
chmod 1777 "$root/tmp"
printf '%s\n' A > "$root/etc/veyra/deployment-id"
printf '%s\n' atomic-v1 > "$root/etc/veyra/deployment-mode"
for script in veyra-deployment.sh veyra-initramfs-select.sh \
    build-veyra-init.sh; do
    install -m755 "$scriptdir/$script" "$root/usr/local/lib/veyra/$script"
done
install -m755 "$scriptdir/veyra-bootctl.py" "$root/usr/local/sbin/veyra-bootctl"
# Confirm newly booted A/B roots only after the normal OpenRC runlevel starts.
mkdir -p "$root/etc/init.d" "$root/etc/runlevels/default"
install -m755 "$scriptdir/veyra-boot-confirm.initd" "$root/etc/init.d/veyra-boot-confirm"
ln -s /etc/init.d/veyra-boot-confirm "$root/etc/runlevels/default/veyra-boot-confirm"

# Build a real initramfs using the selected deployment's kernel modules.
# The Alpine-provided init remains untouched; -i selects a patched copy.
source_init="$root/usr/share/mkinitfs/initramfs-init"
[ -f "$source_init" ] || die 'installed Alpine mkinitfs source missing'
patched="$store/boot-state/veyra-init"
VEYRA_MKINITFS_INIT="$source_init" sh "$scriptdir/build-veyra-init.sh" "$patched"
found=0
for modules in "$root"/lib/modules/*; do
    [ -d "$modules" ] || continue
    found=1
    kernel=${modules##*/}
    mkinitfs -b "$root" -c "$root/etc/mkinitfs/mkinitfs.conf" \
        -i "$patched" -o "$root/boot/initramfs-lts" "$kernel" ||
        die "failed to generate Veyra A initramfs for $kernel"
done
[ "$found" -eq 1 ] || die 'no installed kernel modules'
[ -s "$root/boot/initramfs-lts" ] || die 'missing deployed initramfs'
# The old /boot/vmlinuz-lts and initramfs-lts are not modified: manual
# conventional recovery remains possible if initramfs deployment fails.
python3 "$scriptdir/veyra-bootctl.py" --store "$store" init \
    --uuid "$uuid" --fstype "$filesystem" --default A --adopt-legacy-grub \
    ${VEYRA_ATOMIC_TEST_SERIAL:+--serial-console} ||
    die 'failed to write an atomic GRUB selection'
echo "Veyra A/B conversion prepared on $filesystem ($uuid); original root preserved"
