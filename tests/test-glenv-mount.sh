#!/bin/sh
# Run only inside an isolated privileged mount namespace in GitHub Actions.
# No disks are partitioned and all bind mounts live under a temporary root.
set -eu

[ "$(id -u)" -eq 0 ] || { echo 'mount namespace test requires root' >&2; exit 1; }
[ -e /proc/self/ns/mnt ] || { echo 'Linux mount namespace unavailable' >&2; exit 1; }

tmp=$(mktemp -d /tmp/veyra-glenv-mount.XXXXXX)
host="$tmp/host/runtime"
user="$tmp/userroot/run/glenv/runtime"
cleanup() {
    if mountpoint -q "$user" 2>/dev/null; then
        umount "$user" || true
    fi
    if mountpoint -q "$host" 2>/dev/null; then
        umount "$host" || true
    fi
    rm -rf "$tmp"
}
trap cleanup 0
trap 'exit 1' 1 2 3 15

mkdir -p "$tmp/store/versions/slot-A" "$tmp/userroot"
printf 'glenv release mount fixture\n' > "$tmp/store/versions/slot-A/glenv-manifest.json"
ln -s "$tmp/store/versions/slot-A" "$tmp/selected"

export VEYRA_GLENV_STORE="$tmp/store"
export VEYRA_GLENV_SELECTED="$tmp/selected"
export VEYRA_GLENV_RUNTIME_MOUNT="$host"
export VEYRA_GLENV_USER_ROOT="$tmp/userroot"

sh scripts/glenv-boot-mount.sh --check
sh scripts/glenv-boot-mount.sh

mountpoint -q "$host" || { echo 'Host runtime not mounted' >&2; exit 1; }
mountpoint -q "$user" || { echo 'User runtime not mounted' >&2; exit 1; }
test -f "$host/glenv-manifest.json"
cmp -s "$host/glenv-manifest.json" "$user/glenv-manifest.json"

if touch "$host/not-writable" 2>/dev/null; then
    echo 'Host glenv runtime bind mount is writable!' >&2
    exit 1
fi
if touch "$user/not-writable" 2>/dev/null; then
    echo 'User glenv runtime bind mount is writable!' >&2
    exit 1
fi

printf 'glenv host/user read-only bind mounts passed in isolated namespace\n'
