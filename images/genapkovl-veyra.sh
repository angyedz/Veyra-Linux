#!/bin/sh
# Run inside fakeroot with the image build DESTDIR as working directory.
set -eu
host="${1:-veyra}"
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)

mkdir -p etc/apk etc/sddm.conf.d etc/skel/Desktop etc/skel/.config/autostart etc/sudoers.d \
    etc/conf.d etc/firefox/policies etc/polkit-1/rules.d \
    etc/nix etc/veyra \
    etc/init.d etc/runlevels/sysinit etc/runlevels/boot etc/runlevels/default \
    etc/calamares/modules etc/calamares/branding/veyra \
    usr/local/bin usr/local/lib/veyra usr/share/applications \
    usr/share/veyra/fastfetch usr/share/pixmaps etc/fastfetch \
    etc/skel/.config/fastfetch etc/skel/.config/neofetch
mkdir -p etc/apk/keys
if [ -n "${VEYRA_ISO_REPO_PUBLIC_KEY:-}" ] && [ -s "$VEYRA_ISO_REPO_PUBLIC_KEY" ]; then
    install -m 0644 "$VEYRA_ISO_REPO_PUBLIC_KEY" etc/apk/keys/veyra-iso.rsa.pub
fi
for key in "$root"/packages/keys/*.pub; do
    [ -s "$key" ] || continue
    install -m 0644 "$key" "etc/apk/keys/$(basename "$key")"
done
for key in "$root"/dist/calamares/*.pub; do
    [ -s "$key" ] || continue
    install -m 0644 "$key" "etc/apk/keys/$(basename "$key")"
done
printf '%s\n' veyra > etc/hostname
printf '%s\n' 'Veyra Linux — Lightweight by design. Compatible by nature.' > etc/motd
printf '%s\n' 'Veyra Linux' > etc/issue
printf '%s\n' 'Veyra Linux development live image' > etc/veyra-release
cat > etc/nix/nix.conf <<'NIX'
extra-experimental-features = nix-command flakes
NIX
cat > etc/veyra/dialogrc <<'DIALOGRC'
use_colors = ON
use_shadow = OFF
screen_color = (WHITE,BLACK,OFF)
shadow_color = (BLACK,BLACK,OFF)
dialog_color = (WHITE,BLACK,OFF)
title_color = (WHITE,BLUE,ON)
border_color = (CYAN,BLACK,ON)
button_active_color = (WHITE,BLUE,ON)
button_inactive_color = (CYAN,BLACK,OFF)
button_key_active_color = (YELLOW,BLUE,ON)
button_key_inactive_color = (RED,BLACK,ON)
button_label_active_color = (WHITE,BLUE,ON)
button_label_inactive_color = (WHITE,BLACK,OFF)
inputbox_color = (WHITE,BLACK,OFF)
DIALOGRC
cat > etc/conf.d/zram-init <<'ZRAM'
load_on_start=yes
unload_on_stop=no
num_devices=1
type0=swap
size0=2048
ZRAM
cat > etc/firefox/policies/policies.json <<'FIREFOX'
{"policies":{"HardwareAcceleration":false}}
FIREFOX
cat > etc/polkit-1/rules.d/49-veyra-live.rules <<'POLKIT'
polkit.addRule(function(action, subject) {
    if (subject.user === "veyra") {
        return polkit.Result.YES;
    }
});
POLKIT
cp "$root/branding/os-release" etc/os-release
printf '%s\n' 'DISTRIB_ID=Veyra' 'DISTRIB_RELEASE=1.0' 'DISTRIB_CODENAME=glacier' 'DISTRIB_DESCRIPTION="Veyra Linux 1.0 (Glacier)"' > etc/lsb-release
cp "$root/branding/fastfetch/config.jsonc" etc/fastfetch/config.jsonc
cp "$root/branding/fastfetch/config.jsonc" etc/skel/.config/fastfetch/config.jsonc
cp "$root/branding/fastfetch/logo.txt" usr/share/veyra/fastfetch/logo.txt
cat > etc/skel/.config/neofetch/config.conf <<'NEOFETCH'
image_backend="ascii"
image_source="/usr/share/veyra/fastfetch/logo.txt"
ascii_distro="off"
NEOFETCH
cp "$root/branding/veyra-logo.svg" usr/share/pixmaps/veyra-logo.svg

# Alpine initramfs installs this package set from the ISO's offline repository
# to tmpfs; no conventional root= disk is used.
{
    printf '%s\n' alpine-base
    grep -vE '^[[:space:]]*(#|$)' "$root/images/packages-desktop.txt"
    for package in vpkg veyra-glenv; do
        if [ -n "$(find "$root/packages/repo/x86_64" -maxdepth 1 -name "$package-*.apk" -print -quit 2>/dev/null)" ]; then
            printf '%s\n' "$package"
        fi
    done
} > etc/apk/world

cp "$root/scripts/bootstrap.sh" usr/local/lib/veyra/bootstrap.sh
cp "$root/scripts/setup-pkgrepo.sh" usr/local/lib/veyra/setup-pkgrepo.sh
cp "$root/scripts/compat.sh" usr/local/lib/veyra/compat.sh
cp "$root/scripts/smoke.sh" usr/local/lib/veyra/smoke.sh
# Development-only Go manager is kept separate from the original glenv
# executable and installer. Neither boot helper is enabled automatically.
cp "$root/scripts/glenv-boot-pin.sh" usr/local/lib/veyra/glenv-boot-pin.sh
cp "$root/scripts/glenv-boot-mount.sh" usr/local/lib/veyra/glenv-boot-mount.sh
manager="$root/dist/glenv-manager/glenv-manager"
if [ -f "$manager" ]; then
    [ -x "$manager" ] || { echo "glenv manager artifact is not executable" >&2; exit 1; }
    cp "$manager" usr/local/lib/veyra/glenv-manager
    chmod 755 usr/local/lib/veyra/glenv-manager
elif [ "${VEYRA_REQUIRE_GLENV_MANAGER:-0}" = 1 ]; then
    echo "Required development glenv manager artifact missing: $manager" >&2
    exit 1
fi
cp "$root/images/veyra-live.initd" etc/init.d/veyra-live
cp "$root/images/veyra-live-mode.initd" etc/init.d/veyra-live-mode
cp "$root/images/veyra-x11-sockets.initd" etc/init.d/veyra-x11-sockets
cp "$root/images/veyra-live-mode.sh" usr/local/lib/veyra/live-mode.sh
cp "$root/images/veyra-tui-install.sh" usr/local/lib/veyra/tui-install.sh
cp "$root/images/veyra-live-user.sh" usr/local/lib/veyra/live-user.sh
cp "$root/images/veyra-plasma-watchdog.sh" usr/local/lib/veyra/plasma-watchdog.sh
cp "$root/images/veyra-install.sh" usr/local/bin/veyra-install
cp "$root/scripts/installer-tui.sh" usr/local/bin/veyra-install-tui
cp "$root/scripts/installer-copy.sh" usr/local/lib/veyra/installer-copy.sh
cp "$root/scripts/installer-prepare.sh" usr/local/lib/veyra/installer-prepare.sh
cp "$root/scripts/installer-desktop.sh" usr/local/lib/veyra/installer-desktop.sh
cp "$root/scripts/installer-hardware.sh" usr/local/lib/veyra/installer-hardware.sh
cp "$root/scripts/hardware-detect.sh" usr/local/lib/veyra/hardware-detect.sh
cp "$root/calamares/branding/veyra/"*.svg etc/calamares/branding/veyra/
cp "$root/calamares/branding/veyra/veyra-logo.png" etc/calamares/branding/veyra/veyra-logo.png
cp "$root/calamares/settings.conf" etc/calamares/settings.conf
cp "$root/calamares/modules/"*.conf etc/calamares/modules/
cp "$root/calamares/branding/veyra/branding.desc" etc/calamares/branding/veyra/branding.desc
cp "$root/calamares/branding/veyra/show.qml" etc/calamares/branding/veyra/show.qml
chmod 755 etc/init.d/veyra-live etc/init.d/veyra-live-mode \
    etc/init.d/veyra-x11-sockets usr/local/lib/veyra/live-user.sh usr/local/lib/veyra/live-mode.sh \
    usr/local/lib/veyra/tui-install.sh usr/local/lib/veyra/plasma-watchdog.sh \
    usr/local/bin/veyra-install usr/local/bin/veyra-install-tui \
    usr/local/lib/veyra/installer-copy.sh usr/local/lib/veyra/installer-prepare.sh \
    usr/local/lib/veyra/installer-desktop.sh usr/local/lib/veyra/installer-hardware.sh \
    usr/local/lib/veyra/hardware-detect.sh \
    usr/local/lib/veyra/glenv-boot-pin.sh usr/local/lib/veyra/glenv-boot-mount.sh

cat > usr/local/bin/veyra-setup <<'SETUP'
#!/bin/sh
exec sh /usr/local/lib/veyra/bootstrap.sh "$@"
SETUP
chmod 755 usr/local/bin/veyra-setup

cat > etc/sddm.conf.d/10-veyra-live.conf <<'SDDM'
[General]
DisplayServer=x11

[Autologin]
User=veyra
Session=plasma.desktop
Relogin=true
SDDM

# The live image is ephemeral and reset on reboot, so its user can administer
# the live system without a password. installer-prepare.sh removes this rule.
cat > etc/sudoers.d/veyra-live <<'SUDO'
Defaults:veyra env_keep += "DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS QT_QPA_PLATFORM XAUTHORITY"
veyra ALL=(ALL:ALL) NOPASSWD: ALL
SUDO
chmod 0440 etc/sudoers.d/veyra-live

# Seed a stable Plasma session for newly created installed accounts. These
# files are copied from /etc/skel by both Calamares and the guided installer.
cat > etc/skel/.config/kwinrc <<'KWIN'
[Compositing]
Enabled=false
KWIN
cat > etc/skel/.config/autostart/veyra-plasma-watchdog.desktop <<'AUTOSTART'
[Desktop Entry]
Type=Application
Name=Veyra Plasma recovery
Comment=Restart the desktop shell if it exits
Exec=/usr/local/lib/veyra/plasma-watchdog.sh
Terminal=false
AUTOSTART

cat > usr/share/applications/veyra-install.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Install Veyra Linux
Comment=Install Veyra Linux onto your computer
Exec=veyra-install
Icon=drive-harddisk
Terminal=false
Categories=System;
DESKTOP
# Recovery tools are intentionally available only in the live rescue environment.
# No custom recovery implementation: both programs come from Alpine's TestDisk package.
cat > usr/share/applications/veyra-testdisk.desktop <<'TESTDISK'
[Desktop Entry]
Type=Application
Name=TestDisk — Recover Partitions
Comment=Recover lost partitions and repair disk partition tables (advanced)
Exec=konsole -e pkexec /usr/bin/testdisk
Icon=drive-harddisk
Terminal=false
Categories=System;Utility;
TESTDISK
cat > usr/share/applications/veyra-photorec.desktop <<'PHOTOREC'
[Desktop Entry]
Type=Application
Name=PhotoRec — Recover Files
Comment=Recover deleted files to a different storage device
Exec=konsole -e pkexec /usr/bin/photorec
Icon=drive-removable-media
Terminal=false
Categories=System;Utility;
PHOTOREC
# Disk rescue launchers open trusted upstream TestDisk/PhotoRec in Konsole.
# Require explicit authentication; never run disk recovery as the live user.
cat > usr/local/bin/veyra-testdisk <<'RECOVERY'
#!/bin/sh
exec konsole --hold -e sudo /usr/bin/testdisk
RECOVERY
cat > usr/local/bin/veyra-photorec <<'RECOVERY'
#!/bin/sh
exec konsole --hold -e sudo /usr/bin/photorec
RECOVERY
chmod 755 usr/local/bin/veyra-testdisk usr/local/bin/veyra-photorec
cat > usr/share/applications/veyra-testdisk.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=TestDisk (Disk Recovery)
Comment=Recover partitions and repair partition tables (advanced)
Exec=veyra-testdisk
Icon=drive-harddisk
Terminal=false
Categories=System;Utility;
DESKTOP
cat > usr/share/applications/veyra-photorec.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=PhotoRec (File Recovery)
Comment=Recover lost files from disks and memory cards
Exec=veyra-photorec
Icon=drive-removable-media
Terminal=false
Categories=System;Utility;
DESKTOP
cp usr/share/applications/veyra-install.desktop 'etc/skel/Desktop/Install Veyra Linux.desktop'
chmod 755 etc/skel/Desktop/Install\ Veyra\ Linux.desktop

cat > usr/share/applications/veyra-install-tui.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Install Veyra Linux (text mode)
Comment=Guided terminal installer for Veyra Linux
Exec=konsole -e sudo /usr/local/bin/veyra-install-tui
Icon=utilities-terminal
Terminal=false
Categories=System;
DESKTOP
cp usr/share/applications/veyra-install-tui.desktop 'etc/skel/Desktop/Install Veyra Linux Text.desktop'
chmod 755 etc/skel/Desktop/Install\ Veyra\ Linux\ Text.desktop

# KDE/Wayland needs eudev for input devices, DRM and seat management.
for svc in udev udev-trigger udev-settle; do
    ln -s "/etc/init.d/$svc" "etc/runlevels/sysinit/$svc"
done
ln -s /etc/init.d/udev-postmount etc/runlevels/default/udev-postmount
ln -s /etc/init.d/zram-init etc/runlevels/boot/zram-init

# Live-specific services never get enabled on an installed target.
ln -s /etc/init.d/veyra-live etc/runlevels/boot/veyra-live
ln -s /etc/init.d/veyra-live-mode etc/runlevels/boot/veyra-live-mode
for service in dbus elogind networkmanager sddm; do
    ln -s "/etc/init.d/$service" "etc/runlevels/default/$service"
done

tar -czf "$host.apkovl.tar.gz" etc usr
