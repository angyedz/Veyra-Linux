#!/bin/sh
# Non-destructive prerequisite probe for Veyra's proposed dual environment.
# This is NOT a container launcher, a security proof, or an installer step.
set -eu

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }

command -v unshare >/dev/null 2>&1 || skip 'util-linux unshare unavailable'
command -v readlink >/dev/null 2>&1 || skip 'readlink unavailable'
[ -r /proc/self/uid_map ] || skip 'user namespaces unavailable'

outer_userns=$(readlink /proc/self/ns/user)
outer_mountns=$(readlink /proc/self/ns/mnt)
outer_netns=$(readlink /proc/self/ns/net)
outer_pidns=$(readlink /proc/self/ns/pid)

# -r maps namespace UID 0 to the invoking non-root host UID.
# This probe must never run as host root: mapping host root would defeat
# the very privilege separation we are checking.
[ "$(id -u)" -ne 0 ] || skip 'run as an ordinary host user, not root'

if ! unshare --user --map-root-user --mount --pid --net --ipc --fork --mount-proc \
    sh -c '
        set -eu
        [ "$(id -u)" -eq 0 ] || exit 10
        [ "$$" -eq 1 ] || exit 11
        [ "$(readlink /proc/self/ns/user)" != "$1" ] || exit 12
        [ "$(readlink /proc/self/ns/mnt)" != "$2" ] || exit 13
        [ "$(readlink /proc/self/ns/net)" != "$3" ] || exit 14
        [ "$(readlink /proc/self/ns/pid)" != "$4" ] || exit 15
        # Namespace root must map to an unprivileged host identity.
        # The caller checked its own UID before entering.
        awk "NR==1 { if (\$1 != 0 || \$2 == 0) exit 1 }" /proc/self/uid_map
    ' sh "$outer_userns" "$outer_mountns" "$outer_netns" "$outer_pidns"; then
    fail 'namespace prerequisites failed (kernel policy or missing support)'
fi

printf '%s\n' 'PASS: unprivileged user/mount/PID/network namespace prerequisites'
printf '%s\n' 'NOTE: no rootfs isolation, OpenRC, sudo, VPN, KDE or host protection has been validated'
