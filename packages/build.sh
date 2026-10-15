#!/bin/sh
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
command -v abuild >/dev/null || { echo 'Install alpine-sdk and set up abuild signing keys' >&2; exit 1; }
command -v go >/dev/null || { echo 'Install go' >&2; exit 1; }
command -v git >/dev/null || { echo 'Install git' >&2; exit 1; }
for name in vpkg veyra-glenv; do
    (cd "$root/packages/src/$name" && abuild -r)
done
mkdir -p "$root/packages/repo/x86_64"
out="${REPODEST:-$HOME/packages}"
find "$out" -type f \( -name '*.apk' -o -name 'APKINDEX.tar.gz' \) -exec cp -f {} "$root/packages/repo/x86_64/" \;
echo "Built packages copied to packages/repo/x86_64/"
