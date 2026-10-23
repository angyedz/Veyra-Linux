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
sh tests/test-iso-manifest.sh
[ -f calamares/settings.conf ]
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
grep -q 'need localmount elogind' images/veyra-live.initd
grep -q "sed -i '/\^tty1::respawn:/d' /etc/inittab" images/veyra-live-mode.sh
if grep -q '^tty1::respawn:' images/inittab-veyra; then
    echo 'The live image must not start a tty1 autologin from inittab' >&2
    exit 1
fi
grep -q 'tty1::respawn:/sbin/agetty --autologin veyra' images/veyra-live-mode.sh
grep -q 'inittab-veyra.*etc/inittab' images/genapkovl-veyra.sh
grep -q 'sed -i.*tty1::respawn' scripts/installer-desktop.sh
grep -q 'DisplayServer=x11' scripts/installer-desktop.sh
grep -q 'zz-veyra-live.conf' scripts/installer-copy.sh
grep -q '/tmp/.X11-unix' images/veyra-live-user.sh
grep -q "sddm_uid=\$(id -u sddm)" images/veyra-live-user.sh
grep -q 'find images branding scripts calamares -type f' images/mkimg.veyra.sh
grep -q 'VEYRA_TEST_CALAMARES_AUTOSTART=' images/mkimg.veyra.sh
grep -q 'veyra-live-mode' images/genapkovl-veyra.sh
grep -q 'tui-install.sh' images/veyra-install.sh
grep -q 'XAUTHORITY' images/veyra-install.sh
grep -q 'sudo -n --preserve-env' images/veyra-install.sh
grep -q 'VEYRA_TEST_CALAMARES_AUTOSTART' images/genapkovl-veyra.sh
grep -q 'calamares-autostart-diagnostic.sh' images/genapkovl-veyra.sh
grep -q 'VEYRA_DIAGNOSTIC_AUTOSTART:' images/calamares-autostart-diagnostic.sh
grep -q 'veyra-calamares-diagnostic.lock' images/calamares-autostart-diagnostic.sh
grep -q '^lock_dir=/tmp$' images/calamares-autostart-diagnostic.sh
grep -q 'veyra-install --tui' images/veyra-install-tui.sh
grep -q 'NOPASSWD: ALL' images/genapkovl-veyra.sh
grep -q '49-veyra-live.rules' images/genapkovl-veyra.sh
grep -q '49-veyra-live.rules' scripts/installer-prepare.sh
grep -q 'etc/sudoers.d/veyra-live' tests/test-installed-qemu.py
grep -q 'etc/polkit-1/rules.d/49-veyra-live.rules' tests/test-installed-qemu.py
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
grep -q '^      - locale$' calamares/settings.conf
grep -q '^      - keyboard$' calamares/settings.conf
test -f calamares/modules/locale.conf
grep -q '^useSystemTimezone: false' calamares/modules/locale.conf
test -f scripts/hardware-detect.sh
grep -q 'Session=plasma.desktop' images/genapkovl-veyra.sh
grep -q 'apk add veyra-glenv@veyra' scripts/bootstrap.sh
grep -q 'apk add vpkg@veyra' scripts/bootstrap.sh
grep -q 'setup-pkgrepo.sh' scripts/bootstrap.sh
grep -q 'apk add nix nix-openrc' scripts/bootstrap.sh
if grep -Eiq 'VPN|WireGuard|OpenVPN|OpenConnect' README.md; then
    echo 'Keep README product-focused; put technical details in docs.' >&2
    exit 1
fi

# Validate the Veyra image profile without fetching packages.
(
    profile_standard() { apks=alpine-base; }
    # shellcheck disable=SC1091
    . ./images/mkimg.veyra.sh
    all_sections='kernel apks apkovl veyra_apks'
    profile_veyra
    [ "$image_name" = veyra-linux ]
    [ "$apkovl" = images/genapkovl-veyra.sh ]
    case " $apks " in *" nix "* ) : ;; * ) exit 1 ;; esac
    case " $all_sections " in *" apks "* ) exit 1 ;; esac
    case " $all_sections " in *" veyra_apks "* ) : ;; * ) exit 1 ;; esac
    [ "$(printf '%s\n' "$all_sections" | tr ' ' '\n' | grep -xc veyra_apks)" -eq 1 ]
)

# The image overlay is reproducible and contains our setup script.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
printf '%s\n' 'veyra-builder-test.rsa.pub' > "$tmpdir/temporary-apk-keys.txt"
(cd "$tmpdir" && VEYRA_TEMP_APK_KEYS_MANIFEST="$tmpdir/temporary-apk-keys.txt" \
    sh "$root/images/genapkovl-veyra.sh" veyra)
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/hostname'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/veyra/temporary-apk-keys'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/veyra/temporary-apk-keys | grep -qx 'veyra-builder-test.rsa.pub'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/os-release'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/fastfetch/config.jsonc'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/neofetch/config.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/veyra/fastfetch/logo.txt'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-setup'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-install-tui'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-testdisk.desktop'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-photorec.desktop'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" 'etc/skel/Desktop/Install Veyra Linux.desktop' | grep -qx 'Exec=/usr/local/bin/veyra-install'
tar -tvzf "$tmpdir/veyra.apkovl.tar.gz" | grep 'etc/skel/Desktop/Install Veyra Linux.desktop$' | grep -q '^-rwxr-xr-x'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/hostname | grep -qx veyra
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/sddm.conf.d/zz-veyra-live.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/sudoers.d/veyra-live'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/polkit-1/rules.d/49-veyra-live.rules'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/sudoers.d/veyra-live | grep -qx 'veyra ALL=(root) NOPASSWD: ALL'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/polkit-1/rules.d/49-veyra-live.rules | grep -q 'subject.user === "veyra" && subject.local && subject.active'
tar -tvzf "$tmpdir/veyra.apkovl.tar.gz" | grep 'etc/sudoers.d/veyra-live$' | grep -q '^-r--r-----'
tar -tvzf "$tmpdir/veyra.apkovl.tar.gz" | grep 'etc/polkit-1/rules.d/49-veyra-live.rules$' | grep -q '^-rw-r--r--'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/init.d/veyra-live'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/init.d/veyra-live-mode'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/runlevels/boot/veyra-live-mode'
if tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/runlevels/default/veyra-live-mode'; then
    echo 'TTY chooser must run during boot, before the default runlevel starts SDDM' >&2
    exit 1
fi
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/live-mode.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/tui-install.sh'
tar -tvzf "$tmpdir/veyra.apkovl.tar.gz" | grep 'usr/local/lib/veyra/live-mode.sh$' | grep -q '^-rwxr-xr-x'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/settings.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/modules/locale.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/desktop-plasma.svg'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/veyra-logo.svg'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-hardware.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-desktop.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-copy.sh'
if tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/xdg/autostart/veyra-calamares-diagnostic.desktop'; then
    echo 'Diagnostic Calamares autostart must not enter normal live images' >&2
    exit 1
fi

mkdir "$tmpdir/diagnostic"
(cd "$tmpdir/diagnostic" && VEYRA_TEST_CALAMARES_AUTOSTART=1 \
    sh "$root/images/genapkovl-veyra.sh" veyra)
tar -tzf "$tmpdir/diagnostic/veyra.apkovl.tar.gz" \
    | grep -qx 'etc/xdg/autostart/veyra-calamares-diagnostic.desktop'
tar -tzf "$tmpdir/diagnostic/veyra.apkovl.tar.gz" \
    | grep -qx 'usr/local/lib/veyra/calamares-autostart-diagnostic.sh'
tar -xOf "$tmpdir/diagnostic/veyra.apkovl.tar.gz" \
    etc/xdg/autostart/veyra-calamares-diagnostic.desktop \
    | grep -qx 'Exec=/usr/local/lib/veyra/calamares-autostart-diagnostic.sh'

printf 'Veyra static and overlay tests passed\n'
