#!/bin/sh
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
command -v abuild >/dev/null || { echo 'Install alpine-sdk and set up abuild signing keys' >&2; exit 1; }
command -v go >/dev/null || { echo 'Install go' >&2; exit 1; }
command -v git >/dev/null || { echo 'Install git' >&2; exit 1; }
# Build leaf packages first; the meta package depends on the signed native APKs.
for dir in "$root"/packages/src/*; do
    [ -d "$dir" ] || continue
    [ "${dir##*/}" = veyra-meta ] && continue
    (cd "$dir" && abuild -r)
done
(cd "$root/packages/src/veyra-meta" && abuild -r)
mkdir -p "$root/packages/repo/x86_64"
out="${REPODEST:-$HOME/packages}"
find "$out" -type f \( -name '*.apk' -o -name 'APKINDEX.tar.gz' \) -exec cp -f {} "$root/packages/repo/x86_64/" \;
echo "Built packages copied to packages/repo/x86_64/"
