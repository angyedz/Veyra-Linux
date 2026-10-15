#!/bin/sh
# Install the selected desktop, or configure a console-only system.
# The selection comes from Calamares and is strictly validated.
set -eu
target="${1:?missing target path}"
choice="${2:-}"
case "$target" in /|''|/tmp|/mnt|/run) echo 'Invalid target path' >&2; exit 1 ;; esac
[ -f "$target/etc/apk/world" ] || { echo 'Missing target Alpine installation' >&2; exit 1; }
mountpoint -q "$target" || { echo 'Target not mounted' >&2; exit 1; }
case "$choice" in
    plasma|gnome|xfce|lxqt|minimal) ;;
    *) echo "Invalid desktop choice: $choice" >&2; exit 2 ;;
esac

case "$choice" in
    plasma)
        display_manager=sddm
        # Live ISO already contains Plasma, no network fetch needed here.
        ;;
    gnome)
        display_manager=gdm
        chroot "$target" apk add --no-cache gnome gdm gdm-openrc
        ;;
    xfce)
        display_manager=lightdm
        chroot "$target" apk add --no-cache \
            xfce4 xfce4-terminal xfce4-screensaver \
            lightdm lightdm-openrc lightdm-gtk-greeter gvfs font-dejavu
        ;;
    lxqt)
        display_manager=sddm
        chroot "$target" apk add --no-cache \
            lxqt-desktop qterminal openbox sddm sddm-openrc
        ;;
    minimal)
        display_manager=
        ;;
esac

if [ "$choice" != plasma ]; then
    # These desktop apps are explicitly in the live ISO's apk world.
    # The shared Wayland/X11/graphics stack is retained as needed.
    chroot "$target" apk del \
        plasma-desktop plasma-workspace kwin plasma-nm plasma-pa \
        breeze breeze-icons sddm-breeze polkit-kde-agent-1 \
        systemsettings kscreen kde-cli-tools plasma-systemmonitor \
        plasma-workspace-wallpapers konsole dolphin ark kate spectacle kcalc \
        xdg-desktop-portal-kde
fi
if [ "$choice" = minimal ]; then
    # Keep the installed system console-first; hardware setup may add only
    # the graphics libraries required by detected devices.
    chroot "$target" apk del \
        xorg-server xwayland qt6-qtwayland \
        mesa-dri-gallium mesa-egl mesa-gbm mesa-vulkan-swrast \
        font-noto font-noto-emoji polkit \
        udisks2 upower pipewire pipewire-pulse wireplumber pipewire-alsa \
        xdg-desktop-portal firefox
fi
if [ "$display_manager" != sddm ]; then
    chroot "$target" rc-update del sddm default || true
    chroot "$target" apk del sddm sddm-openrc
fi
if [ -n "$display_manager" ]; then
    chroot "$target" rc-update add "$display_manager" default
fi

mkdir -p "$target/etc/veyra"
printf '%s\n' "$choice" > "$target/etc/veyra/desktop"
echo "Desktop installed: $choice (display manager: $display_manager)"
