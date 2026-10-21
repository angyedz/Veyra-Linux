#!/bin/sh
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
cd "$root"

for f in scripts/*.sh images/*.sh tests/*.sh scripts/*.initd; do
    [ -e "$f" ] || continue
    sh -n "$f"
done
[ -f README.md ]
[ -f .github/workflows/ci.yml ]
[ -f .github/workflows/iso.yml ]
[ -f scripts/test-iso.sh ]
[ -f images/packages-desktop.txt ]
sh tests/test-system-packages.sh
[ -f calamares/settings.conf ]
grep -q 'check: \[ ram, internet \]' calamares/modules/welcome.conf
if grep -q 'requiredStorage:' calamares/modules/welcome.conf; then
    echo 'Calamares must allow installation to begin on a blank drive' >&2
    exit 1
fi
grep -qx linux-lts images/packages-desktop.txt
sh -n images/veyra-install-tui.sh
if grep -Eq '^grub(-bios|-efi)?$' images/packages-desktop.txt; then
    echo 'GRUB must only be installed on the disk-backed target' >&2
    exit 1
fi
grep -q 'apk add --no-cache grub grub-bios grub-efi' scripts/installer-prepare.sh
grep -qx fastfetch images/packages-desktop.txt
grep -qx 'ID=veyra' branding/os-release
grep -qx 'ID_LIKE=alpine' branding/os-release
grep -qx plasma-desktop images/packages-desktop.txt
test -f images/veyra-tui-install.sh
test -f images/veyra-live-mode.sh
test -f images/veyra-x11-sockets.initd
grep -q 'serial_console' images/veyra-live-mode.sh
grep -q 'veyra-x11-sockets.initd' images/genapkovl-veyra.sh
grep -q 'rc-update add veyra-x11-sockets default' scripts/installer-desktop.sh
grep -q 'veyra-live-mode' images/genapkovl-veyra.sh
grep -q 'tui-install.sh' images/veyra-install.sh
grep -q 'veyra-install --tui' images/veyra-install-tui.sh
grep -q 'runlevels/boot/veyra-live-mode' scripts/installer-prepare.sh
# The TTY installer must mount target pseudo-filesystems before chroot/APK steps.
dev_mount_line=$(grep -n '^    mount --rbind /dev ' images/veyra-tui-install.sh | cut -d: -f1)
# Match the literal $lib token in the install script; no shell expansion intended.
# shellcheck disable=SC2016
prepare_line=$(grep -n '^    sh "$lib/installer-prepare.sh"' images/veyra-tui-install.sh | cut -d: -f1)
[ -n "$dev_mount_line" ] && [ -n "$prepare_line" ] && [ "$dev_mount_line" -lt "$prepare_line" ]
grep -q 'setup-pkgrepo.sh' tests/test-installed-qemu.py
grep -qx plasma-workspace images/packages-desktop.txt
for app in firefox konsole dolphin veyra-calamares testdisk tzdata btrfs-progs xfsprogs f2fs-tools; do
    grep -qx "$app" images/packages-desktop.txt || { echo "Missing live app: $app" >&2; exit 1; }
done
for app in systemsettings kscreen kde-cli-tools plasma-systemmonitor plasma-workspace-wallpapers ark kate spectacle kcalc; do
    if grep -qx "$app" images/packages-desktop.txt; then
        echo "Unwanted KDE app in minimal live image: $app" >&2
        exit 1
    fi
done
grep -qx qt6-qtwayland images/packages-desktop.txt
grep -qx sddm-openrc images/packages-desktop.txt
grep -qx dialog images/packages-desktop.txt
grep -q 'DIALOGRC=/etc/veyra/dialogrc' scripts/installer-tui.sh
grep -q 'veyra-wheel' scripts/installer-tui.sh
grep -q 'visudo -c -f /etc/sudoers.d/veyra-wheel' scripts/installer-tui.sh
grep -q 'etc/skel/.config/autostart' images/genapkovl-veyra.sh
grep -q 'etc/skel/.config/kwinrc' images/genapkovl-veyra.sh
test -f scripts/hardware-detect.sh
grep -q 'Session=plasma.desktop' images/genapkovl-veyra.sh
grep -q 'NOPASSWD: ALL' images/genapkovl-veyra.sh
grep -q 'QT_QPA_PLATFORM XAUTHORITY' images/genapkovl-veyra.sh
grep -q 'QT_QPA_PLATFORM,XAUTHORITY' images/veyra-install.sh
grep -q 'installer-tui.sh' images/genapkovl-veyra.sh
grep -q 'slideshow: "show.qml"' calamares/branding/veyra/branding.desc
grep -q 'productLogo: "veyra-logo.png"' calamares/branding/veyra/branding.desc
grep -q 'branding/veyra/show.qml' images/genapkovl-veyra.sh
grep -q 'branding/veyra/veyra-logo.png' images/genapkovl-veyra.sh
grep -qx zram-init images/packages-desktop.txt
grep -q 'HardwareAcceleration.*false' images/genapkovl-veyra.sh
grep -q 'plasma-watchdog.sh' images/veyra-live-user.sh
grep -qF "rm -f \"\$target/etc/sudoers.d/veyra-live\"" scripts/installer-prepare.sh
grep -qF "rm -f \"\$target/etc/polkit-1/rules.d/49-veyra-live.rules\"" scripts/installer-prepare.sh
grep -qF "rm -f \"\$target/etc/firefox/policies/policies.json\"" scripts/installer-prepare.sh
# Match the literal target path with quotes; no shell expansion is intended.
# shellcheck disable=SC2016
grep -qF 'chmod 1777 "$target/tmp"' scripts/installer-prepare.sh
grep -q '49-veyra-live.rules' images/genapkovl-veyra.sh

grep -q 'ENABLE_GLENV' scripts/bootstrap.sh
grep -q '^      - locale$' calamares/settings.conf
grep -q '^      - keyboard$' calamares/settings.conf
test -f calamares/modules/locale.conf
grep -q '^useSystemTimezone: false' calamares/modules/locale.conf
test -f scripts/hardware-detect.sh
grep -q 'Session=plasma.desktop' images/genapkovl-veyra.sh
grep -q 'apk add veyra-glenv' scripts/bootstrap.sh
grep -q 'apk add vpkg' scripts/bootstrap.sh
grep -q 'setup-pkgrepo.sh' scripts/bootstrap.sh
grep -q 'apk add nix nix-openrc' scripts/bootstrap.sh
grep -q 'extra-experimental-features = nix-command flakes' scripts/bootstrap.sh
grep -q 'extra-experimental-features = nix-command flakes' images/genapkovl-veyra.sh
grep -q 'veyra-pkgrepo/main/stable/v1' scripts/setup-pkgrepo.sh
grep -q 'VEYRA_ISO_REPO_PUBLIC_KEY' images/genapkovl-veyra.sh


if grep -Eiq 'VPN|WireGuard|OpenVPN|OpenConnect' README.md; then
    echo 'Keep README product-focused; put technical details in docs.' >&2
    exit 1
fi

# Validate the Veyra image profile without fetching packages.
(
    profile_standard() { apks=alpine-base; }
    # shellcheck disable=SC1091
    . ./images/mkimg.veyra.sh
    profile_veyra
    [ "$image_name" = veyra-linux ]
    [ "$apkovl" = images/genapkovl-veyra.sh ]
    case " $apks " in *" nix "* ) : ;; * ) exit 1 ;; esac
)

# The image overlay is reproducible and contains our setup script.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
printf '%s\n' 'public-key-fixture' > "$tmpdir/iso.rsa.pub"
(cd "$tmpdir" && VEYRA_ISO_REPO_PUBLIC_KEY="$tmpdir/iso.rsa.pub" sh "$root/images/genapkovl-veyra.sh" veyra)
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/hostname'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/veyra/dialogrc'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/apk/keys/veyra-iso.rsa.pub'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/apk/keys/veyra-iso.rsa.pub | grep -qx 'public-key-fixture'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/os-release'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/fastfetch/config.jsonc'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/neofetch/config.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/veyra/fastfetch/logo.txt'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-setup'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-install-tui'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-testdisk.desktop'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-photorec.desktop'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/hostname | grep -qx veyra
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/nix/nix.conf | grep -qx 'extra-experimental-features = nix-command flakes'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/sddm.conf.d/10-veyra-live.conf'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/sudoers.d/veyra-live | grep -qx 'veyra ALL=(ALL:ALL) NOPASSWD: ALL'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/conf.d/zram-init | grep -qx 'size0=2048'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/firefox/policies/policies.json | grep -q '"HardwareAcceleration":false'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/polkit-1/rules.d/49-veyra-live.rules | grep -q 'subject.user === "veyra"'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/init.d/veyra-live'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/plasma-watchdog.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/init.d/veyra-live-mode'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/init.d/veyra-x11-sockets'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/runlevels/boot/veyra-live-mode'
if tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/runlevels/default/veyra-live-mode'; then
    echo 'TTY chooser must run during boot, before the default runlevel starts SDDM' >&2
    exit 1
fi
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/live-mode.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/tui-install.sh'
tar -tvzf "$tmpdir/veyra.apkovl.tar.gz" | grep 'usr/local/lib/veyra/live-mode.sh
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/settings.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/modules/locale.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/desktop-plasma.svg'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/show.qml'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/veyra-logo.png'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-hardware.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-install-tui'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-install-tui.desktop'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/kwinrc'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/autostart/veyra-plasma-watchdog.desktop'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/skel/.config/kwinrc | grep -qx 'Enabled=false'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-desktop.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-copy.sh'

printf 'Veyra static and overlay tests passed\n'
 | grep -q '^-rwxr-xr-x'
tar -tvzf "$tmpdir/veyra.apkovl.tar.gz" | grep 'etc/init.d/veyra-x11-sockets
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/settings.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/modules/locale.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/desktop-plasma.svg'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/show.qml'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/veyra-logo.png'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-hardware.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-install-tui'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-install-tui.desktop'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/kwinrc'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/autostart/veyra-plasma-watchdog.desktop'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/skel/.config/kwinrc | grep -qx 'Enabled=false'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-desktop.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-copy.sh'

printf 'Veyra static and overlay tests passed\n'
 | grep -q '^-rwxr-xr-x'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/settings.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/modules/locale.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/desktop-plasma.svg'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/show.qml'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/veyra-logo.png'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-hardware.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-install-tui'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-install-tui.desktop'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/kwinrc'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/autostart/veyra-plasma-watchdog.desktop'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/skel/.config/kwinrc | grep -qx 'Enabled=false'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-desktop.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-copy.sh'

printf 'Veyra static and overlay tests passed\n'
 | grep -q '^-rwxr-xr-x'
tar -tvzf "$tmpdir/veyra.apkovl.tar.gz" | grep 'etc/init.d/veyra-x11-sockets
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/settings.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/modules/locale.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/desktop-plasma.svg'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/show.qml'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/veyra-logo.png'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-hardware.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-install-tui'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-install-tui.desktop'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/kwinrc'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/autostart/veyra-plasma-watchdog.desktop'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/skel/.config/kwinrc | grep -qx 'Enabled=false'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-desktop.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-copy.sh'

printf 'Veyra static and overlay tests passed\n'
 | grep -q '^-rwxr-xr-x'
tar -tvzf "$tmpdir/veyra.apkovl.tar.gz" | grep 'etc/init.d/veyra-x11-sockets
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/settings.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/modules/locale.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/desktop-plasma.svg'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/show.qml'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/veyra-logo.png'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-hardware.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-install-tui'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-install-tui.desktop'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/kwinrc'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/autostart/veyra-plasma-watchdog.desktop'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/skel/.config/kwinrc | grep -qx 'Enabled=false'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-desktop.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-copy.sh'

printf 'Veyra static and overlay tests passed\n'
 | grep -q '^-rwxr-xr-x'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/settings.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/modules/locale.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/desktop-plasma.svg'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/show.qml'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/veyra-logo.png'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-hardware.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-install-tui'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-install-tui.desktop'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/kwinrc'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/autostart/veyra-plasma-watchdog.desktop'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/skel/.config/kwinrc | grep -qx 'Enabled=false'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-desktop.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-copy.sh'

printf 'Veyra static and overlay tests passed\n'
 | grep -q '^-rwxr-xr-x'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/settings.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/modules/locale.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/desktop-plasma.svg'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/show.qml'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/veyra-logo.png'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-hardware.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-install-tui'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-install-tui.desktop'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/kwinrc'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/autostart/veyra-plasma-watchdog.desktop'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/skel/.config/kwinrc | grep -qx 'Enabled=false'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-desktop.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-copy.sh'

printf 'Veyra static and overlay tests passed\n'
 | grep -q '^-rwxr-xr-x'
tar -tvzf "$tmpdir/veyra.apkovl.tar.gz" | grep 'etc/init.d/veyra-x11-sockets
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/settings.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/modules/locale.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/desktop-plasma.svg'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/show.qml'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/veyra-logo.png'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-hardware.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-install-tui'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-install-tui.desktop'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/kwinrc'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/autostart/veyra-plasma-watchdog.desktop'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/skel/.config/kwinrc | grep -qx 'Enabled=false'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-desktop.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-copy.sh'

printf 'Veyra static and overlay tests passed\n'
 | grep -q '^-rwxr-xr-x'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/settings.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/modules/locale.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/desktop-plasma.svg'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/show.qml'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/veyra-logo.png'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-hardware.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-install-tui'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-install-tui.desktop'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/kwinrc'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/autostart/veyra-plasma-watchdog.desktop'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/skel/.config/kwinrc | grep -qx 'Enabled=false'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-desktop.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-copy.sh'

printf 'Veyra static and overlay tests passed\n'
