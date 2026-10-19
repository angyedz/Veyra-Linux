#!/bin/sh
# Non-root regression for the recovery image builder's fail-closed behavior.
set -eu
repo=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT HUP INT TERM
builder="$repo/scripts/build-veyra-recovery.sh"
sh -n "$repo/scripts/veyra-recovery-init.sh"
sh -n "$builder"
if sh "$builder" 'invalid/kernel' "$temp/out.img" > /dev/null 2>&1; then
    echo 'Accepted unsafe kernel version' >&2; exit 1
fi
if sh "$builder" 'test-kernel' relative.img > /dev/null 2>&1; then
    echo 'Accepted relative output path' >&2; exit 1
fi
printf 'do-not-touch\n' > "$temp/existing.img"
if sh "$builder" 'test-kernel' "$temp/existing.img" > /dev/null 2>&1; then
    echo 'Overwrote existing recovery artifact' >&2; exit 1
fi
test "$(cat "$temp/existing.img")" = do-not-touch
grep -q 'cat /proc/partitions' "$repo/scripts/veyra-recovery-init.sh"
grep -q 'cat /proc/cmdline' "$repo/scripts/veyra-recovery-init.sh"
echo 'Recovery builder safety preflight passed'
