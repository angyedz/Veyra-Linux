#!/bin/sh
# Start the disposable ublk loop target in its own mount namespace.
set -eu
BB=/bin/busybox
UBLK=/usr/sbin/ublk

if [ ! -b /dev/vda ] || [ ! -c /dev/ublk-control ]; then
    echo 'VEYRA_SNAPCORE_FAILURE: ublk backing or control device is unavailable' >&2
    exit 1
fi

# This directory holds ublk daemon state. Keep it private in the server's
# mount namespace so the user-root namespace cannot replace its pid metadata.
"$BB" mount -t tmpfs -o mode=0700,nosuid,nodev tmpfs /run
"$BB" mkdir -p /run/ublksrvd
"$BB" chmod 0700 /run/ublksrvd
export UBLKSRV_RUN_DIR=/run/ublksrvd
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

add_output=$($UBLK add -t loop -n 0 -f /dev/vda 2>&1) || {
    echo "VEYRA_SNAPCORE_FAILURE: ublk add failed: $add_output" >&2
    exit 1
}
printf '%s\n' "$add_output"

attempt=0
while [ "$attempt" -lt 15 ] && [ ! -b /dev/ublkb0 ]; do
    "$BB" sleep 1
    attempt=$((attempt + 1))
done
[ -b /dev/ublkb0 ] || {
    echo 'VEYRA_SNAPCORE_FAILURE: ublk did not create /dev/ublkb0' >&2
    exit 1
}

list_output=$($UBLK list -n 0 -v 2>&1) || {
    echo "VEYRA_SNAPCORE_FAILURE: ublk list failed: $list_output" >&2
    exit 1
}
printf '%s\n' "$list_output"
# ublk add reports the live daemon pid in its human-readable output.
# The verbose list JSON currently reports ublksrv_pid=-1.
daemon_pid=$(printf '%s\n%s\n' "$add_output" "$list_output" | \
    "$BB" sed -n 's/.*daemon pid \([0-9][0-9]*\).*/\1/p' | "$BB" sed -n '1p')
case "$daemon_pid" in
    ''|*[!0-9]*)
        echo 'VEYRA_SNAPCORE_FAILURE: ublk server pid was not reported' >&2
        exit 1
        ;;
esac

init_mount_ns=$("$BB" readlink /proc/1/ns/mnt)
ublk_mount_ns=$("$BB" readlink "/proc/$daemon_pid/ns/mnt")
[ -n "$init_mount_ns" ] && [ -n "$ublk_mount_ns" ] &&
    [ "$init_mount_ns" != "$ublk_mount_ns" ] || {
        echo 'VEYRA_SNAPCORE_FAILURE: ublk server shares the client mount namespace' >&2
        exit 1
    }
echo 'VEYRA_SNAPCORE_UBLK_DEVICE_PASS device=/dev/ublkb0 backing=/dev/vda mountns=separate'
