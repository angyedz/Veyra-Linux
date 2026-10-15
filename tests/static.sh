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
grep -qx plasma-desktop images/packages-desktop.txt
grep -qx qt6-qtwayland images/packages-desktop.txt
grep -qx sddm-openrc images/packages-desktop.txt
grep -q 'Session=plasma.desktop' images/genapkovl-veyra.sh
grep -q 'GLENV_REF' scripts/bootstrap.sh
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
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'usr/local/bin/veyra-setup'
tar -xOf "$tmpdir/veyra.apkovl.tar.gz" etc/hostname | grep -qx veyra
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/sddm.conf.d/10-veyra-live.conf'
tar -tzf "$tmpdir/veyra.apkovl.tar.gz" | grep -qx 'etc/init.d/veyra-live'

printf 'Veyra static and overlay tests passed\n'
