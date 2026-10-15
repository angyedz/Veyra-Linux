#!/bin/sh
# Run inside fakeroot with the image build DESTDIR as working directory.
set -eu
host="${1:-veyra}"
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)

mkdir -p etc/apk etc/sddm.conf.d etc/skel/Desktop etc/sudoers.d \
    etc/init.d etc/runlevels/sysinit etc/runlevels/boot etc/runlevels/default \
    etc/calamares/modules etc/calamares/branding/veyra \
    usr/local/bin usr/local/lib/veyra usr/share/applications
printf '%s\n' veyra > etc/hostname
printf '%s\n' 'Veyra Linux — Lightweight by design. Compatible by nature.' > etc/motd
printf '%s\n' 'Veyra Linux' > etc/issue
printf '%s\n' 'Veyra Linux development live image' > etc/veyra-release

# Alpine initramfs installs this package set from the ISO's offline repository
# to tmpfs; no conventional root= disk is used.
{
    printf '%s\n' alpine-base
    grep -vE '^[[:space:]]*(#|$)' "$root/images/packages-desktop.txt"
} > etc/apk/world

cp "$root/scripts/bootstrap.sh" usr/local/lib/veyra/bootstrap.sh
cp "$root/scripts/compat.sh" usr/local/lib/veyra/compat.sh
cp "$root/scripts/smoke.sh" usr/local/lib/veyra/smoke.sh
cp "$root/images/veyra-live.initd" etc/init.d/veyra-live
cp "$root/images/veyra-live-user.sh" usr/local/lib/veyra/live-user.sh
cp "$root/images/veyra-install.sh" usr/local/bin/veyra-install
cp "$root/scripts/installer-copy.sh" usr/local/lib/veyra/installer-copy.sh
cp "$root/scripts/installer-prepare.sh" usr/local/lib/veyra/installer-prepare.sh
cp "$root/calamares/settings.conf" etc/calamares/settings.conf
cp "$root/calamares/modules/"*.conf etc/calamares/modules/
cp "$root/calamares/branding/veyra/branding.desc" etc/calamares/branding/veyra/branding.desc
chmod 755 etc/init.d/veyra-live usr/local/lib/veyra/live-user.sh \
    usr/local/bin/veyra-install \
    usr/local/lib/veyra/installer-copy.sh usr/local/lib/veyra/installer-prepare.sh

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

# Root privileges only for the explicitly selected graphical installer.
# Live environment account has no permanent password.
cat > etc/sudoers.d/veyra-live <<'SUDO'
Defaults:veyra env_keep += "DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS QT_QPA_PLATFORM"
veyra ALL=(root) NOPASSWD: /usr/bin/calamares
SUDO
chmod 0440 etc/sudoers.d/veyra-live

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
cp usr/share/applications/veyra-install.desktop etc/skel/Desktop/Install\ Veyra\ Linux.desktop
chmod 755 etc/skel/Desktop/Install\ Veyra\ Linux.desktop

# KDE/Wayland needs eudev for input devices, DRM and seat management.
for svc in udev udev-trigger udev-settle; do
    ln -s "/etc/init.d/$svc" "etc/runlevels/sysinit/$svc"
done
ln -s /etc/init.d/udev-postmount etc/runlevels/default/udev-postmount

# Live-specific services never get enabled on an installed target.
ln -s /etc/init.d/veyra-live etc/runlevels/boot/veyra-live
for service in dbus elogind networkmanager sddm; do
    ln -s "/etc/init.d/$service" "etc/runlevels/default/$service"
done

tar -czf "$host.apkovl.tar.gz" etc usr
