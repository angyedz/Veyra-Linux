#!/bin/sh
# Veyra's supported desktop is KDE Plasma, with SDDM as its login manager.
set -eu
target="${1:?missing target path}"
choice="${2:-}"
case "$target" in /|''|/tmp|/mnt|/run) echo 'Invalid target path' >&2; exit 1 ;; esac
[ -f "$target/etc/apk/world" ] || { echo 'Missing target Alpine installation' >&2; exit 1; }
mountpoint -q "$target" || { echo 'Target not mounted' >&2; exit 1; }
case "$choice" in
    plasma) ;;
    *) echo "Veyra supports KDE Plasma only; refusing desktop: $choice" >&2; exit 2 ;;
esac

# Plasma is already in the live image; retain the tested SDDM session.
chroot "$target" rc-update add sddm default

mkdir -p "$target/etc/veyra"
printf '%s\n' "$choice" > "$target/etc/veyra/desktop"
echo 'Desktop installed: KDE Plasma (display manager: SDDM)'
