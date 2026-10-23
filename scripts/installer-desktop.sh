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
if [ -f "$target/etc/inittab" ]; then
    # PID 1 reads inittab before SDDM starts; do not leave a respawning getty
    # holding the VT that SDDM needs for its authenticated session.
    sed -i '/^tty1::respawn:/d' "$target/etc/inittab"
fi
chroot "$target" rc-update add sddm default

# Alpine's sddm-openrc start hook waits briefly for /run/user/<sddm-uid>.
# The Live image creates it in its ephemeral veyra-live service; installed
# systems need a small service to prepare it after elogind starts.
scriptdir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
runtime_service="$scriptdir/veyra-sddm-runtime.initd"
[ -f "$runtime_service" ] && [ ! -L "$runtime_service" ] || {
    echo 'Missing safe SDDM runtime service.' >&2
    exit 1
}
install -m 0755 "$runtime_service" "$target/etc/init.d/veyra-sddm-runtime"
chroot "$target" rc-update add veyra-sddm-runtime default

mkdir -p "$target/etc/veyra"
mkdir -p "$target/etc/sddm.conf.d"
cat > "$target/etc/sddm.conf.d/zz-veyra.conf" <<'SDDM'
[General]
DisplayServer=x11
SDDM
printf '%s\n' "$choice" > "$target/etc/veyra/desktop"
echo 'Desktop installed: KDE Plasma (display manager: SDDM)'
