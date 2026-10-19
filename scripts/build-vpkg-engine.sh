#!/bin/sh
# Reproducible experimental Veyra build of apk-tools 2.14.x under our own
# vpkg-engine name. Does not install into, modify, or replace the host APK.
set -eu

[ -f /etc/alpine-release ] || {
    echo 'vpkg-engine builds require Alpine (use disposable Alpine CI).' >&2
    exit 1
}
project=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
work=${VEYRA_VPKG_BUILDROOT:-"$project/.build/vpkg-engine"}
dest=${VEYRA_VPKG_OUTPUT:-"$project/dist/vpkg-engine"}
case "$work" in /*) :;; *) echo 'Build root must be absolute' >&2; exit 2;; esac
case "$dest" in /*) :;; *) echo 'Build output must be absolute' >&2; exit 2;; esac
[ "$work" != / ] && [ "$dest" != / ] || exit 2

# Exact upstream version used on the Veyra Alpine 3.22 base.
upstream_sha=7bf85c7cc18a0b6056f376421fb5d4c2a806daad
src="$work/apk-tools"
mkdir -p "$work" "$dest"

if [ ! -e "$src/.git" ]; then
    git clone --depth 1 --branch v2.14.12 \
        https://github.com/alpinelinux/apk-tools.git "$src"
fi
actual=$(git -C "$src" rev-parse HEAD)
[ "$actual" = "$upstream_sha" ] || {
    echo "Wrong upstream apk-tools revision: $actual" >&2
    exit 1
}
# Source must be clean before applying our versioned downstream patch.
git -C "$src" reset --hard "$upstream_sha"
git -C "$src" clean -fdx
patch -d "$src" -p1 --fuzz=0 < "$project/packaging/vpkg-engine/0001-veyra-identity.patch"

# Keep the upstream library/solver/signature verification implementation.
# Do not shadow /sbin/apk on the live host until package ABI integration is
# tested, including mkinitfs, Calamares, abuild and clean bootstrap.
meson setup "$src/output" "$src" \
    --auto-features=disabled \
    -Ddocs=disabled -Dhelp=disabled -Dlua=disabled \
    -Dpython=disabled -Dtests=disabled -Dzstd=disabled \
    -Ddefault_library=static
ninja -C "$src/output" src/apk

install -m 0755 "$src/output/src/apk" "$dest/vpkg-engine"
cp "$src/LICENSE" "$dest/LICENSE.apk-tools"
printf '%s\n' "$upstream_sha" > "$dest/UPSTREAM_COMMIT"
"$dest/vpkg-engine" --version
