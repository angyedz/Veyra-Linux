#!/bin/sh
# Static safety regression for the opt-in namespace prototype.
set -eu
script=$(CDPATH= cd -- "$(dirname "$0")/../scripts" && pwd)/veyra-user-env-prototype.sh
sh -n "$script"
grep -Fq 'id -u' "$script"
grep -Fq 'unshare --user --map-root-user --mount --pid --ipc --net --uts' "$script"
grep -Fq 'mount --make-rprivate /' "$script"
grep -Fq 'pivot_root . .veyra-old-root' "$script"
grep -Fq 'umount -l /.veyra-old-root' "$script"
grep -Fq 'mount -t proc proc /proc' "$script"
grep -Fq 'exec /sbin/init' "$script"
if grep -Eq 'mount --bind[[:space:]]+/(dev|sys|run|boot|var/lib/veyra/store)' "$script"; then
    echo 'unexpected privileged host mount' >&2
    exit 1
fi
echo 'PASS: namespace launcher syntax and static isolation invariants'
