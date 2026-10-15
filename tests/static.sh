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
if grep -Eq '^grub(-bios|-efi)?$' images/packages-desktop.txt; then
    echo 'GRUB must only be installed on the disk-backed target' >&2
    exit 1
fi
grep -q 'apk add --no-cache grub grub-bios grub-efi' scripts/installer-prepare.sh
grep -qx plasma-desktop images/packages-desktop.txt
grep -qx qt6-qtwayland images/packages-desktop.txt
grep -qx sddm-openrc images/packages-desktop.txt
test -f calamares/modules/packagechooser-desktop.conf
test -f scripts/hardware-detect.sh
grep -q 'Session=plasma.desktop' images/genapkovl-veyra.sh
grep -q 'NOPASSWD: ALL' images/genapkovl-veyra.sh
grep -qx zram-init images/packages-desktop.txt
grep -q 'HardwareAcceleration.*false' images/genapkovl-veyra.sh
grep -q 'plasma-watchdog.sh' images/veyra-live-user.sh
grep -q 'rm -f "$target/etc/sudoers.d/veyra-live"' scripts/installer-prepare.sh
grep -q 'rm -f "$target/etc/firefox/policies/policies.json"' scripts/installer-prepare.sh
grep -q '49-veyra-live.rules' images/genapkovl-veyra.sh
grep -q 'rm -f "$target/etc/polkit-1/rules.d/49-veyra-live.rules"' scripts/installer-prepare.sh
grep -q 'GLENV_REF' scripts/bootstrap.sh
grep -q 'apk add nix nix-openrc' scripts/bootstrap.sh
grep -q 'extra-experimental-features = nix-command flakes' scripts/bootstrap.sh
grep -q 'extra-experimental-features = nix-command flakes' images/genapkovl-veyra.sh
grep -q 'raw.githubusercontent.com/angyedz/Veyra-Linux/main/packages/repo/x86_64' scripts/installer-prepare.sh
grep -q 'VEYRA_ISO_REPO_PUBLIC_KEY' images/genapkovl-veyra.sh
grep -q "github.event_name == 'push' && github.ref == 'refs/heads/main'" .github/workflows/packages.yml
grep -q 'contents: write' .github/workflows/packages.yml
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
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/apk/keys/veyra-iso.rsa.pub'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/apk/keys/veyra-iso.rsa.pub | grep -qx 'public-key-fixture'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-setup'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/hostname | grep -qx veyra
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/nix/nix.conf | grep -qx 'extra-experimental-features = nix-command flakes'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/sddm.conf.d/10-veyra-live.conf'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/sudoers.d/veyra-live | grep -qx 'veyra ALL=(ALL:ALL) NOPASSWD: ALL'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/conf.d/zram-init | grep -qx 'size0=2048'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/firefox/policies/policies.json | grep -q '"HardwareAcceleration":false'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/polkit-1/rules.d/49-veyra-live.rules | grep -q 'subject.user === "veyra"'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/init.d/veyra-live'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/plasma-watchdog.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/settings.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/calamares/branding/veyra/desktop-plasma.svg'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-hardware.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-desktop.sh'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/lib/veyra/installer-copy.sh'

printf 'Veyra static and overlay tests passed\n'
