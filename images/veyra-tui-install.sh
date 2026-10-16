#!/bin/sh
# Veyra text-mode installer. No KDE, Qt or Calamares required.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo veyra-install --tui" >&2; exit 1; }
[ -r /etc/veyra-release ] || { echo "Run this installer from Veyra Live ISO." >&2; exit 1; }
lib=/usr/local/lib/veyra
target=/mnt/veyra-target
trap 'printf "\\nInstallation interrupted. Mounted target left intact at %s\\n" "$target"' HUP INT TERM
say() { printf '\\n%s\\n' "$*"; }
ask() { printf '%s' "$1"; IFS= read -r answer || exit 1; }
pause() { printf 'Press Enter to continue... '; IFS= read -r _ || :; }
menu() {
    while :; do
        clear 2>/dev/null || :
        printf '=== Veyra Linux — TUI installer ===\\n'
        printf '1) List disks and partitions\\n'
        printf '2) Partition disks manually (cfdisk)\\n'
        printf '3) Install Veyra onto prepared partitions\\n'
        printf '4) Open shell for manual installation\\n'
        printf '5) Exit\\n\\n'
        ask 'Select [1-5]: '
        case "$answer" in
            1) lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS; pause ;;
            2) ask 'Disk device (e.g. /dev/sda or /dev/nvme0n1): '; disk=$answer
               [ -b "$disk" ] || { say "Not a block device."; pause; continue; }
               cfdisk "$disk" || : ;;
            3) install_veyra; pause ;;
            4) sh ;;
            5) exit 0 ;;
        esac
    done
}
valid_device() { [ -b "$1" ] && [ "$1" != /dev/null ]; }
install_veyra() {
    say "WARNING: This installer FORMATS the chosen root partition and overwrites its data."
    say "Prepare GPT partitions using cfdisk first. EFI installations need a FAT32 EFI system partition."
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
    ask 'Root partition device: '; rootdev=$answer
    valid_device "$rootdev" || { say 'Invalid root partition.'; return; }
    case "$rootdev" in /dev/*) ;; *) say 'Invalid path.'; return ;; esac
    [ "$(lsblk -dn -o TYPE "$rootdev")" = part ] || { say 'Select a partition, not an entire disk.'; return; }
    ask 'Root filesystem [ext4/btrfs/xfs/f2fs] (default ext4): '; fs=${answer:-ext4}
    case "$fs" in ext4|btrfs|xfs|f2fs) ;; *) say 'Unsupported filesystem.'; return ;; esac
    efi=
    if [ -d /sys/firmware/efi ]; then
        ask 'EFI system partition (existing FAT32, will NOT format): '; efi=$answer
        valid_device "$efi" || { say 'Invalid EFI partition.'; return; }
        [ "$efi" != "$rootdev" ] || { say 'Root and EFI must differ.'; return; }
        [ "$(blkid -s TYPE -o value "$efi" 2>/dev/null)" = vfat ] || { say 'EFI partition must be FAT32.'; return; }
    fi
    ask 'Desktop [plasma/xfce/lxqt/gnome] (default plasma): '; desktop=${answer:-plasma}
    case "$desktop" in plasma|xfce|lxqt|gnome) ;; *) say 'Invalid desktop.'; return ;; esac
    ask 'Computer hostname [veyra]: '; hostname=${answer:-veyra}
    case "$hostname" in *[!a-zA-Z0-9-]*|''|-*|*-) say 'Invalid hostname.'; return ;; esac
    ask 'New user name: '; username=$answer
    case "$username" in *[!a-z_0-9-]*|''|[!a-z_]* ) say 'Invalid username.'; return ;; esac
    [ "$username" != root ] && [ "$username" != veyra ] || { say 'Reserved username.'; return; }
    say "ROOT WILL BE FORMATTED: $rootdev ($fs). Desktop: $desktop. EFI: ${efi:-BIOS}."
    ask 'Type ERASE to continue: '
    [ "$answer" = ERASE ] || { say 'Cancelled.'; return; }
    [ ! -e "$target/etc/apk/world" ] || { say "Target $target is already populated; unmount/clean it first."; return; }
    mkdir -p "$target"
    mountpoint -q "$target" && { say 'Target mountpoint is busy.'; return; }
    case "$fs" in
        ext4) mkfs.ext4 -F "$rootdev" ;;
        btrfs) mkfs.btrfs -f "$rootdev" ;;
        xfs) mkfs.xfs -f "$rootdev" ;;
        f2fs) mkfs.f2fs -f "$rootdev" ;;
    esac
    mount "$rootdev" "$target"
    if [ -n "$efi" ]; then
        mkdir -p "$target/boot/efi"
        mount "$efi" "$target/boot/efi"
    fi
    say 'Copying live system...'
    sh "$lib/installer-copy.sh" "$target"
    say 'Preparing repositories, kernel and base system (network required)...'
    sh "$lib/installer-prepare.sh" "$target"
    sh "$lib/installer-desktop.sh" "$target" "$desktop"
    sh "$lib/installer-hardware.sh" "$target"
    printf '%s\\n' "$hostname" > "$target/etc/hostname"
    mkdir -p "$target/etc"
    root_uuid=$(blkid -s UUID -o value "$rootdev")
    [ -n "$root_uuid" ] || { say 'Missing root UUID'; return 1; }
    printf 'UUID=%s / %s defaults 0 1\\n' "$root_uuid" "$fs" > "$target/etc/fstab"
    if [ -n "$efi" ]; then
        efi_uuid=$(blkid -s UUID -o value "$efi")
        printf 'UUID=%s /boot/efi vfat defaults 0 2\\n' "$efi_uuid" >> "$target/etc/fstab"
    fi
    for dir in dev proc sys run; do mkdir -p "$target/$dir"; done
    mount --rbind /dev "$target/dev"
    mount --make-rslave "$target/dev"
    mount -t proc proc "$target/proc"
    mount --rbind /sys "$target/sys"
    mount --make-rslave "$target/sys"
    mount --bind /run "$target/run"
    say 'Set root password:'
    chroot "$target" passwd root
    chroot "$target" adduser -D -s /bin/bash "$username"
    chroot "$target" addgroup "$username" wheel || :
    say "Set password for $username:"
    chroot "$target" passwd "$username"
    if [ -n "$efi" ]; then
        chroot "$target" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Veyra --removable
    else
        ask 'BIOS boot disk (WHOLE disk, e.g. /dev/sda): '; bootdisk=$answer
        valid_device "$bootdisk" || { say 'Invalid boot disk.'; return 1; }
        [ "$(lsblk -dn -o TYPE "$bootdisk")" = disk ] || { say 'BIOS boot target must be a whole disk.'; return 1; }
        chroot "$target" grub-install --target=i386-pc "$bootdisk"
    fi
    chroot "$target" grub-mkconfig -o /boot/grub/grub.cfg
    say "Installation finished. Unmount $target and reboot when ready."
    say "Manual cleanup: umount -R $target"
}
menu
