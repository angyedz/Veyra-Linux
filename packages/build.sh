#!/bin/sh
# Manual fallback publisher: canonical APKBUILDs and build logic live in pkgrepo.
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
src="$root/pkgrepo-source"
[ -f "$src/scripts/build.sh" ] || {
    echo 'Checkout angyedz/veyra-pkgrepo into pkgrepo-source first' >&2
    exit 1
}
# The vpkg Go sources remain in the distribution checkout.
if [ ! -e "$src/distro-source" ]; then
    ln -s .. "$src/distro-source"
fi
sh "$src/scripts/build.sh"
mkdir -p "$root/packages/repo/x86_64"
cp "$src/packages/repo/x86_64/"*.apk "$root/packages/repo/x86_64/"
cp "$src/packages/repo/x86_64/APKINDEX.tar.gz" "$root/packages/repo/x86_64/"
echo 'Built with canonical package recipes from veyra-pkgrepo'
