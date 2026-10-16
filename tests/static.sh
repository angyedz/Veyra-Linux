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
grep -q 'veyra-live-mode' images/genapkovl-veyra.sh
grep -q 'tui-install.sh' images/veyra-install.sh
grep -q 'veyra-install --tui' images/veyra-install-tui.sh
grep -q 'runlevels/default/veyra-live-mode' scripts/installer-prepare.sh
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
grep -q 'apk add veyra-glenv' scripts/bootstrap.sh
grep -q 'apk add vpkg' scripts/bootstrap.sh
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
    profile_veyra
    [ "$image_name" = veyra-linux ]
    [ "$apkovl" = images/genapkovl-veyra.sh ]
    case " $apks " in *" nix "* ) : ;; * ) exit 1 ;; esac
)

# The image overlay is reproducible and contains our setup script.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
(cd "$tmpdir" && sh "$root/images/genapkovl-veyra.sh" veyra)
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/hostname'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/os-release'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/fastfetch/config.jsonc'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/skel/.config/neofetch/config.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/veyra/fastfetch/logo.txt'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-setup'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-install-tui'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-testdisk.desktop'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/share/applications/veyra-photorec.desktop'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/hostname | grep -qx veyra
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/sddm.conf.d/10-veyra-live.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/init.d/veyra-live'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/init.d/veyra-live-mode'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/live-mode.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/tui-install.sh'
tar -tvzf "$tmpdir/veyra.apkovl.tar.gz" | grep 'usr/local/lib/veyra/live-mode.sh$' | grep -q '^-rwxr-xr-x'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/settings.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/modules/locale.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/desktop-plasma.svg'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-hardware.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-desktop.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-copy.sh'

printf 'Veyra static and overlay tests passed\n'
