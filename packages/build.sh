#!/bin/sh
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
command -v abuild >/dev/null || { echo 'Install alpine-sdk and configure signing keys' >&2; exit 1; }
command -v go >/dev/null || { echo 'Install go' >&2; exit 1; }
command -v git >/dev/null || { echo 'Install git' >&2; exit 1; }

# The distro owns vpkg. All other first-party recipes are maintained in
# angyedz/veyra-pkgrepo and checked out by the publishing workflow.
src="${VEYRA_PACKAGE_SOURCES:-$root/pkgrepo-source/src}"
[ -d "$src" ] || { echo "Missing package source checkout: $src" >&2; exit 1; }
(cd "$root/packages/src/vpkg" && abuild -r)
for dir in "$src"/*; do
    [ -f "$dir/APKBUILD" ] || continue
    case "${dir##*/}" in vpkg|veyra-meta) continue ;; esac
    (cd "$dir" && abuild -r)
done
(cd "$src/veyra-meta" && abuild -r)
mkdir -p "$root/packages/repo/x86_64"
out="${REPODEST:-$HOME/packages}"
find "$out" -type f \( -name '*.apk' -o -name 'APKINDEX.tar.gz' \) -exec cp -f {} "$root/packages/repo/x86_64/" \;
echo "Built packages copied to packages/repo/x86_64/"
