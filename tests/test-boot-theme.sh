#!/bin/sh
# Check GRUB assets derive from the canonical Veyra SVG, never a stock icon.
set -eu
repo=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT HUP INT TERM
sh "$repo/scripts/build-veyra-boot-theme.sh" "$temp/generated"
test -s "$temp/generated/theme.txt"
test -s "$temp/generated/veyra-logo.png"
grep -q 'veyra-logo.png' "$temp/generated/theme.txt"
magic=$(od -An -tx1 -N8 "$temp/generated/veyra-logo.png" | tr -d ' \n')
test "$magic" = 89504e470d0a1a0a
if sh "$repo/scripts/build-veyra-boot-theme.sh" "$temp/generated" >/dev/null 2>&1; then
    echo 'Builder overwrote existing GRUB theme' >&2
    exit 1
fi
if sh "$repo/scripts/build-veyra-boot-theme.sh" relative/path >/dev/null 2>&1; then
    echo 'Builder accepted relative output directory' >&2
    exit 1
fi
echo 'Canonical Veyra GRUB PNG asset and safety checks passed'
