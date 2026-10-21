#!/bin/sh
# Verify that the published ISO matches its checksum and is an ISO9660 image.
# This check does not replace QEMU boot or installation tests.
set -eu

iso=${1:?usage: sh scripts/verify-iso-artifact.sh path/to/image.iso}
[ -f "$iso" ] || { echo "Missing ISO: $iso" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo 'sha256sum is required' >&2; exit 1; }
command -v dd >/dev/null || { echo 'dd is required' >&2; exit 1; }

dir=$(dirname "$iso")
name=$(basename "$iso")
expected_file=''
for candidate in "$iso.sha256" "$dir/$name.sha256" "$dir/${name%.iso}.sha256"; do
    if [ -f "$candidate" ]; then
        expected_file=$candidate
        break
    fi
done
if [ -z "$expected_file" ]; then
    for candidate in "$dir"/*.sha256; do
        [ -f "$candidate" ] || continue
        case $(basename "$candidate") in
            *"$name"*|*veyra-linux*) expected_file=$candidate; break ;;
        esac
    done
fi
[ -n "$expected_file" ] || { echo "No ISO SHA256 file found for $name" >&2; exit 1; }

actual=$(sha256sum "$iso" | awk '{print $1}')
# Accept checksums with an optional filename field, but demand exactly
# one matching hash for this image, not just an arbitrary checksum file.
if ! awk -v hash="$actual" -v image="$name" '
  $1 == hash && (NF == 1 || index($0,image)>0) { matched=1 }
  END { exit matched ? 0 : 1 }
' "$expected_file"; then
    echo "ISO SHA256 mismatch: $name ($expected_file)" >&2
    exit 1
fi

# ISO9660 primary volume descriptor starts at sector 16; bytes 1-5
# are the standard identifier CD001.
magic=$(dd if="$iso" bs=2048 skip=16 count=1 2>/dev/null | dd bs=1 skip=1 count=5 2>/dev/null)
if [ "$magic" != CD001 ]; then
    echo "Missing ISO9660 primary volume descriptor in $name" >&2
    exit 1
fi

printf 'Veyra ISO integrity verified: %s\n' "$name"
