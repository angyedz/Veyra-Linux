#!/bin/sh
# Informational kernel prerequisite test; exit 77 means blocked by runner.
set -eu
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
[ "$(id -u)" -ne 0 ] || skip 'run as nonroot user'
for command_name in unshare readlink awk; do
    command -v "$command_name" >/dev/null 2>&1 || skip "missing $command_name"
done
[ -r /proc/self/uid_map ] || skip '/proc/self/uid_map unavailable'
unshare --user --map-root-user -- true >/dev/null 2>&1 ||
    skip 'unprivileged user namespace blocked'
unshare --user --map-root-user --mount --pid --ipc --net \
    --propagation private --fork --mount-proc -- true >/dev/null 2>&1 ||
    skip 'required namespace combination blocked'
userns=$(readlink /proc/self/ns/user)
mountns=$(readlink /proc/self/ns/mnt)
pidns=$(readlink /proc/self/ns/pid)
netns=$(readlink /proc/self/ns/net)
ipcns=$(readlink /proc/self/ns/ipc)
host_uid=$(id -u)
# A successful namespace entry followed by a failed invariant is a real FAIL.
if ! unshare --user --map-root-user --mount --pid --ipc --net \
    --propagation private --fork --mount-proc -- sh -eu -c '
        [ "$(id -u)" -eq 0 ] || exit 10
        [ "$$" -eq 1 ] || exit 11
        [ "$(readlink /proc/self/ns/user)" != "$1" ] || exit 12
        [ "$(readlink /proc/self/ns/mnt)" != "$2" ] || exit 13
        [ "$(readlink /proc/self/ns/pid)" != "$3" ] || exit 14
        [ "$(readlink /proc/self/ns/net)" != "$4" ] || exit 15
        [ "$(readlink /proc/self/ns/ipc)" != "$5" ] || exit 16
        awk -v outer_uid="$6" '"'"'
            $1 == 0 { if ($2 != outer_uid) exit 1; found=1 }
            END { if (!found) exit 1 }
        '"'"' /proc/self/uid_map
    ' sh "$userns" "$mountns" "$pidns" "$netns" "$ipcns" "$host_uid"; then
    fail 'namespace creation succeeded but PID/UID/namespace invariant failed'
fi
echo 'PASS: rootless user/mount/PID/network/IPC namespaces and single-ID mapping'
echo 'NOTE: no rootfs, sudo, KDE, VPN or host confinement proven'
