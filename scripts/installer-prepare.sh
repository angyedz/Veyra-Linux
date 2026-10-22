#!/bin/sh
# Target configuration after the live root has been copied.
set -eu
target="${1:?target root not given}"
case "$target" in
    /|''|/tmp|/mnt|/run) echo 'Refusing dangerous target' >&2; exit 1 ;;
esac
mountpoint -q "$target" || { echo 'Target must be mounted' >&2; exit 1; }
[ -e "$target/etc/apk/world" ] || {
    echo 'Target must contain a complete Alpine root' >&2
    exit 1
}
for d in dev proc sys run tmp media mnt boot/efi; do
    mkdir -p "$target/$d"
done

# Avoid live-user autologin and boot initialization on the installed system.
rm -f "$target/etc/sddm.conf.d/10-veyra-live.conf"
rm -f "$target/etc/sudoers.d/veyra-live"
rm -f "$target/etc/polkit-1/rules.d/49-veyra-live.rules"
rm -f "$target/etc/runlevels/boot/veyra-live"
rm -f "$target/etc/runlevels/boot/veyra-live-mode" "$target/etc/runlevels/default/veyra-live-mode"
rm -f "$target/etc/veyra-release"
rm -f "$target/usr/local/lib/veyra/live-mode.sh" "$target/usr/local/lib/veyra/live-user.sh"
rm -f "$target/usr/local/bin/veyra-install" "$target/usr/local/bin/veyra-install-tui"
rm -f "$target/etc/init.d/veyra-live-mode" "$target/etc/init.d/veyra-live"
# Disk installations must not depend on the live CD's squashfs modloop.
rm -f "$target/etc/runlevels/sysinit/modloop" "$target/etc/runlevels/boot/modloop"
rm -f "$target/usr/share/applications/veyra-install.desktop"
rm -f "$target/usr/share/applications/veyra-testdisk.desktop" "$target/usr/share/applications/veyra-photorec.desktop"
rm -f "$target/etc/skel/Desktop/Install Veyra Linux.desktop"
rm -rf "$target/home/veyra"
if [ -e "$target/etc/passwd" ]; then
    chroot "$target" deluser veyra 2>/dev/null || true
fi

# Installed machines use the stable Alpine repositories rather than
# repositories from removable installation media.
cat > "$target/etc/apk/repositories" <<'REPOS'
https://dl-cdn.alpinelinux.org/alpine/v3.22/main
https://dl-cdn.alpinelinux.org/alpine/v3.22/community
REPOS

# Pin Veyra's trusted public signing key and preserve the package source
# across installation; the live overlay includes this script.
scriptdir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
VEYRA_ROOT="$target" sh "$scriptdir/setup-pkgrepo.sh"

# The new root needs DNS before desktop and firmware downloads begin.
if [ -r /etc/resolv.conf ]; then
    rm -f "$target/etc/resolv.conf"
    cp -L /etc/resolv.conf "$target/etc/resolv.conf"
fi

# Calamares runs only on live media; installed systems must not retain
# the build-specific Calamares package or its temporary local repository.
if chroot "$target" apk info -e veyra-calamares >/dev/null 2>&1; then
    chroot "$target" apk del veyra-calamares
fi

# Install the signed Veyra desktop essentials from the stable repository.
# AppCenter was installed from the ISO's pinned local APK repo; omit it here
# so stable cannot replace this pinned development build with its older published one.
echo 'Installing Veyra desktop applications from the signed repository...'
chroot "$target" apk update
chroot "$target" apk add --no-cache veyra-meta linux-firmware
for package in veyra-meta veyra-appcenter flatpak telegram-desktop linux-firmware; do
    chroot "$target" apk info -e "$package" >/dev/null || {
        echo "Required Veyra desktop package missing after install: $package" >&2
        exit 1
    }
done

# GRUB cannot generate a proper configuration on the RAM-backed live root.
# Install and configure its BIOS/UEFI packages only AFTER the disk filesystem
# has been mounted. This avoids a failed live grub.trigger poisoning APK state.
echo 'Installing GRUB for the disk-backed system...'
chroot "$target" apk add --no-cache grub grub-bios grub-efi

# The Live ISO uses short-lived signing keys for its pinned local APKs and
# temporary package index. Those keys must not become trust anchors on disk.
temporary_keys=/etc/veyra/temporary-apk-keys
if [ -r "$temporary_keys" ]; then
    while IFS= read -r key || [ -n "$key" ]; do
        [ -n "$key" ] || continue
        case "$key" in
            *[!A-Za-z0-9_.@+-]*|.*|*/*)
                echo "Invalid temporary APK key filename: $key" >&2
                exit 1
                ;;
        esac
        rm -f "$target/etc/apk/keys/$key"
    done < "$temporary_keys"
    rm -f "$target/etc/veyra/temporary-apk-keys"
fi

# Alpine live media mounts the kernel modules in a separate squashfs
# modloop, which rsync deliberately does not copy to disk. Restore the
# complete kernel and its modules from the official Alpine repository.
# Remove a possible live-only symlink before extracting the package.
if [ -L "$target/lib/modules" ]; then
    rm -f "$target/lib/modules"
fi
mkdir -p "$target/lib/modules"
echo 'Installing disk kernel and modules from Alpine repositories...'
chroot "$target" apk fix --reinstall linux-lts
[ -f "$target/boot/vmlinuz-lts" ] || {
    echo 'Disk installation has no kernel at /boot/vmlinuz-lts.' >&2
    exit 1
}
found_modules=0
for dir in "$target"/lib/modules/*; do
    if [ -d "$dir" ]; then found_modules=1; break; fi
done
[ "$found_modules" -eq 1 ] || {
    echo 'Disk installation has no kernel module directory.' >&2
    exit 1
}

# Generate a valid 128-bit machine-id. An empty ID prevents D-Bus from starting.
[ -r /proc/sys/kernel/random/uuid ] || { echo 'Missing kernel random UUID source' >&2; exit 1; }
tr -d '-' < /proc/sys/kernel/random/uuid > "$target/etc/machine-id"
if ! grep -Eq '^[[:xdigit:]]{32}$' "$target/etc/machine-id"; then
    echo 'Invalid installed machine-id' >&2
    exit 1
fi
rm -f "$target/var/lib/dbus/machine-id"
echo 'Prepared installed Veyra environment.'
