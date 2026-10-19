#!/bin/sh
# Isolated fixture test: no ISO downloads, mounts, or privileged operations.
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
iso="$tmp/veyra-linux-fixture.iso"
# One synthetic ISO9660 descriptor at sector 16.
dd if=/dev/zero of="$iso" bs=2048 count=17 2>/dev/null
printf 'CD001' | dd of="$iso" bs=1 seek=32769 conv=notrunc 2>/dev/null
sha256sum "$iso" > "$iso.sha256"
sh "$root/scripts/verify-iso-artifact.sh" "$iso"

# A changed image must fail even when the primary volume descriptor survives.
printf 'bad' | dd of="$iso" bs=1 seek=10 conv=notrunc 2>/dev/null
if sh "$root/scripts/verify-iso-artifact.sh" "$iso" >/dev/null 2>&1; then
    echo 'Checksum verifier accepted a modified ISO' >&2
    exit 1
fi

# Valid checksum but invalid volume descriptor must also fail.
printf 'WRONG' | dd of="$iso" bs=1 seek=32769 conv=notrunc 2>/dev/null
sha256sum "$iso" > "$iso.sha256"
if sh "$root/scripts/verify-iso-artifact.sh" "$iso" >/dev/null 2>&1; then
    echo 'ISO9660 verifier accepted an invalid volume descriptor' >&2
    exit 1
fi
echo 'ISO artifact verifier fixture tests passed'
