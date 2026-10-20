#!/bin/sh
# Guided, whole-disk Veyra installer for live TTYs and limited graphics.
set -eu

if [ "$(id -u)" -ne 0 ]; then
    exec sudo /usr/local/bin/veyra-install-tui "$@"
fi
if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo 'Run this installer from a terminal.' >&2
    exit 2
fi
command -v dialog >/dev/null 2>&1 || {
    echo 'The text installer needs the dialog package.' >&2
    exit 1
}

export DIALOGRC=/etc/veyra/dialogrc
export DIALOGOPTS="--colors --no-shadow"
backtitle='Veyra Linux  |  Easy installation'
log=/tmp/veyra-install-tui.log
target=
disk=
rootpart=
efipart=
username=
password=
firmware=bios
disk_modified=0

msg() { dialog --clear --backtitle "$backtitle" --title "$1" --msgbox "$2" 11 76; }
fail() {
    if [ "$disk_modified" -eq 1 ]; then
        detail='The drive may now contain a partial installation. You can restart the installer to try again.'
    else
        detail='No changes were made to the selected drive.'
    fi
    dialog --clear --backtitle "$backtitle" --title 'Installation stopped' \
        --yes-label 'View details' --no-label 'Close' \
        --yesno "$1\n\n$detail\nDetails are in $log." 13 76 || return 0
    [ ! -s "$log" ] || dialog --backtitle "$backtitle" --title 'Diagnostic log' --textbox "$log" 22 88
}
cleanup() {
    if [ -n "$target" ] && mountpoint -q "$target"; then
        umount -R "$target" >>"$log" 2>&1 || true
    fi
    if [ -n "$target" ] && [ "$target" != / ]; then
        rmdir "$target" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

stage() {
    title=$1
    message=$2
    shift 2
    dialog --clear --backtitle "$backtitle" --title "$title" \
        --infobox "$message\n\nThis can take several minutes. Please keep the computer connected to power." 10 76
    if "$@" >>"$log" 2>&1; then
        return 0
    fi
    fail "$title failed. No success screen will be shown."
    return 1
}

check_network() {
    while ! curl -fsS --max-time 8 \
        https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64/APKINDEX.tar.gz \
        -o /dev/null; do
        dialog --backtitle "$backtitle" --title 'Internet connection required' \
            --yes-label 'Try again' --no-label 'Cancel' \
            --yesno 'Veyra needs internet access to install the disk kernel and hardware support.\n\nConnect to Wi-Fi or Ethernet, then choose Try again.' 12 76 || return 1
    done
}

choose_disk() {
    set --
    while read -r device size type; do
        [ "$type" = disk ] || continue
        if lsblk -nrpo MOUNTPOINT "$device" | grep -q '[^[:space:]]'; then
            continue
        fi
        bytes=$(blockdev --getsize64 "$device" 2>/dev/null || echo 0)
        [ "$bytes" -ge 17179869184 ] || continue
        model=$(lsblk -dn -o MODEL "$device" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$model" ] || model='Drive'
        set -- "$@" "$device" "$size  |  $model"
    done <<EOF
$(lsblk -dpn -o NAME,SIZE,TYPE)
EOF
    [ "$#" -gt 0 ] || {
        msg 'No available drive' 'No unmounted drive of at least 16 GB was found. Close other disk tools and try again.'
        return 1
    }
    disk=$(dialog --clear --backtitle "$backtitle" --title 'Step 1 of 3  ·  Choose a drive' \
        --menu 'Choose where Veyra will be installed. Drives smaller than 16 GB or currently mounted are hidden.' \
        18 86 8 "$@" 3>&1 1>&2 2>&3) || return 1
}

collect_account() {
    while :; do
        username=$(dialog --clear --backtitle "$backtitle" --title 'Step 2 of 3  ·  Create your account' \
            --stdout --inputbox 'Choose a username. Use lowercase letters, numbers, _ or -.' \
            10 76 '') || return 1
        if printf '%s\n' "$username" | grep -Eq '^[a-z_][a-z0-9_-]{0,30}$' \
            && ! printf '%s\n' "$username" | grep -Eq '[-_]$'; then
            break
        fi
        msg 'Username not accepted' 'Use 1–31 characters: lowercase letters, numbers, _ or -. The first character must be a letter or _.'
    done
    while :; do
        password=$(dialog --clear --backtitle "$backtitle" --title 'Step 2 of 3  ·  Set a password' \
            --stdout --passwordbox 'Enter a password with at least 8 characters.' 10 76) || return 1
        confirm=$(dialog --clear --backtitle "$backtitle" --title 'Step 2 of 3  ·  Confirm password' \
            --stdout --passwordbox 'Enter the same password again.' 10 76) || return 1
        if [ "${#password}" -ge 8 ] && [ "$password" = "$confirm" ]; then
            unset confirm
            return 0
        fi
        unset password confirm
        msg 'Passwords did not match' 'Enter the same password twice. It must contain at least 8 characters.'
    done
}

format_and_mount() {
    case "$disk" in
        *nvme*n*|*mmcblk*) p1="${disk}p1"; p2="${disk}p2" ;;
        *) p1="${disk}1"; p2="${disk}2" ;;
    esac
    disk_modified=1
    if [ "$firmware" = uefi ]; then
        parted -s "$disk" mklabel gpt \
            mkpart ESP fat32 1MiB 513MiB set 1 esp on \
            mkpart Veyra ext4 513MiB 100%
        efipart=$p1
        rootpart=$p2
    else
        parted -s "$disk" mklabel gpt \
            mkpart primary 1MiB 3MiB set 1 bios_grub on \
            mkpart primary ext4 3MiB 100%
        rootpart=$p2
    fi
    partprobe "$disk"
    udevadm settle || sleep 2
    if [ "$firmware" = uefi ]; then
        mkfs.vfat -F 32 -n VEYRA_EFI "$efipart"
    fi
    mkfs.ext4 -F -L Veyra "$rootpart"
    target=$(mktemp -d /mnt/veyra-install.XXXXXX)
    mount "$rootpart" "$target"
    mkdir -p "$target/boot/efi" "$target/dev" "$target/proc" "$target/sys" "$target/run"
    if [ "$firmware" = uefi ]; then
        mount "$efipart" "$target/boot/efi"
    fi
    for dir in dev sys; do mount --rbind "/$dir" "$target/$dir"; done
    mount -t proc proc "$target/proc"
    mount --rbind /run "$target/run"
}

configure_account() {
    chroot "$target" adduser -D -s /bin/ash "$username"
    for group in audio video input wheel; do
        if ! grep -q "^$group:" "$target/etc/group"; then
            chroot "$target" addgroup -S "$group"
        fi
        chroot "$target" addgroup "$username" "$group"
    done
    cat >"$target/etc/sudoers.d/veyra-wheel" <<'SUDOERS'
%wheel ALL=(ALL:ALL) ALL
SUDOERS
    chmod 0440 "$target/etc/sudoers.d/veyra-wheel"
    chroot "$target" visudo -c -f /etc/sudoers.d/veyra-wheel
    printf '%s:%s\n' "$username" "$password" | chroot "$target" chpasswd
    unset password
    hostname="veyra-$(printf '%s' "$username" | tr '_' '-')"
    printf '%s\n' "$hostname" >"$target/etc/hostname"
    printf '127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost\n' "$hostname" >"$target/etc/hosts"
    root_uuid=$(blkid -s UUID -o value "$rootpart")
    [ -n "$root_uuid" ]
    printf 'UUID=%s / ext4 defaults,noatime 0 1\n' "$root_uuid" >"$target/etc/fstab"
    if [ "$firmware" = uefi ]; then
        efi_uuid=$(blkid -s UUID -o value "$efipart")
        printf 'UUID=%s /boot/efi vfat defaults 0 2\n' "$efi_uuid" >>"$target/etc/fstab"
    fi
}

configure_services_and_bootloader() {
    for service in dbus elogind networkmanager nix-daemon; do
        chroot "$target" rc-update add "$service" default
    done
    if [ "$firmware" = uefi ]; then
        chroot "$target" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
            --bootloader-id=Veyra --no-nvram --removable
    else
        chroot "$target" grub-install --target=i386-pc "$disk"
    fi
    chroot "$target" grub-mkconfig -o /boot/grub/grub.cfg
}

: >"$log"
if ! dialog --clear --backtitle "$backtitle" --title 'Welcome to Veyra' \
    --yes-label 'Start' --no-label 'Cancel' --yesno \
    'This guided installer sets up KDE Plasma and a personal account.\n\nIt uses one whole drive, creates a standard ext4 installation, and erases all data on that drive. Keep important files backed up.' \
    14 76; then
    exit 0
fi

if [ -d /sys/firmware/efi ]; then firmware=uefi; fi
choose_disk || exit 1
check_network || exit 1
collect_account || exit 1

summary="Drive: $disk\nFirmware: $firmware\nDesktop: KDE Plasma\nFilesystem: ext4\nUser: $username\n\nEVERYTHING ON $disk WILL BE ERASED.\n\nContinue only if this is the correct drive and your files are backed up."
if ! dialog --clear --backtitle "$backtitle" --title 'Step 3 of 3  ·  Review and confirm' \
    --yes-label 'Erase drive and install' --no-label 'Go back' --defaultno \
    --yesno "$summary" 17 80; then
    exit 0
fi

if ! stage 'Preparing the drive' 'Creating the standard Veyra disk layout and formatting it…' format_and_mount; then exit 1; fi
if ! stage 'Install Veyra' 'Copying the live system and preparing the disk kernel…' \
    sh /usr/local/lib/veyra/installer-copy.sh "$target"; then exit 1; fi
if ! stage 'Install Veyra' 'Configuring boot files, KDE Plasma and detected hardware…' \
    sh /usr/local/lib/veyra/installer-prepare.sh "$target"; then exit 1; fi
if ! stage 'Install Veyra' 'Creating your account and setting up the desktop…' configure_account; then exit 1; fi
if ! stage 'Install Veyra' 'Installing hardware support and the boot menu…' \
    sh /usr/local/lib/veyra/installer-desktop.sh "$target" plasma; then exit 1; fi
if ! stage 'Install Veyra' 'Installing hardware support and the boot menu…' \
    sh /usr/local/lib/veyra/installer-hardware.sh "$target"; then exit 1; fi
if ! stage 'Install Veyra' 'Finishing bootloader and startup services…' configure_services_and_bootloader; then exit 1; fi

cleanup
target=
dialog --clear --backtitle "$backtitle" --title 'Veyra is ready' \
    --yes-label 'Restart now' --no-label 'Exit' --yesno \
    'Installation finished. Remove the USB drive after shutdown, then start your computer to enter KDE Plasma.' \
    12 76 && reboot
exit 0
