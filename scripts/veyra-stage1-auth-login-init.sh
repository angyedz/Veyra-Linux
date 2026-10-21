#!/bin/sh
# Disposable QEMU initramfs for named password-login testing only.
set -eu
bb=/bin/busybox
manager_pid=0
cleanup() {
    if [ "$manager_pid" -gt 0 ]; then
        /host-supervisor stop >/dev/null 2>&1 || :
        "$bb" kill -TERM "$manager_pid" 2>/dev/null || :
        wait "$manager_pid" 2>/dev/null || :
        manager_pid=0
    fi
}
fail() {
    echo "VEYRA_STAGE1_FAILURE: $*"
    cleanup
    "$bb" sync || :
    "$bb" poweroff -f || :
    exit 1
}
trap cleanup EXIT INT TERM

"$bb" mount -t proc proc /proc
"$bb" mount -t sysfs sysfs /sys
"$bb" mount -t devtmpfs devtmpfs /dev
"$bb" mkdir -p /dev/pts /run /tmp /mnt/veyra-user /mnt/veyra-home
"$bb" mount -t devpts devpts /dev/pts
"$bb" mount -t tmpfs -o mode=0755 tmpfs /run
"$bb" mount -t tmpfs -o mode=1777 tmpfs /tmp
exec </dev/console >/dev/console 2>&1
"$bb" modprobe virtio_pci 2>/dev/null || :
"$bb" modprobe virtio_blk 2>/dev/null || :
"$bb" modprobe ext4 2>/dev/null || :

disk_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -b /dev/vda ]; then disk_ready=1; break; fi
    "$bb" sleep 1
done
[ "$disk_ready" -eq 1 ] || fail "disposable /dev/vda unavailable"
"$bb" mount -t ext4 -o rw /dev/vda /mnt/veyra-user ||
    fail "could not mount the persistent user rootfs"
"$bb" mount -t ext4 -o rw /dev/vdb /mnt/veyra-home ||
    fail "could not mount the separate persistent home volume"
[ -x /mnt/veyra-user/sbin/init ] || fail "user rootfs lacks executable /sbin/init"
[ ! -e /mnt/veyra-home/eve/.veyra-stage1-authenticated-login ] ||
    fail "fresh QEMU home volume already contains an authentication proof"

"/host-supervisor" serve /mnt/veyra-user eve /mnt/veyra-home >/run/veyra-stage1-auth-manager.log 2>&1 &
manager_pid=$!
socket_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if [ -S /run/veyra-user-manager/control.sock ]; then
        socket_ready=1
        break
    fi
    if ! "$bb" kill -0 "$manager_pid" 2>/dev/null; then
        fail "test manager exited before creating its control socket"
    fi
    "$bb" sleep 1
done
[ "$socket_ready" -eq 1 ] || fail "test manager control socket did not become ready"
echo "VEYRA_STAGE1_AUTH_MANAGER_READY account=eve"
start_result=$(/host-supervisor start 2>&1) ||
    fail "named user environment failed to start: $start_result"
case "$start_result" in
    RUNNING\ pid=*\ count=1) ;;
    *) fail "unexpected manager start result: $start_result" ;;
esac
echo "VEYRA_STAGE1_AUTH_ENVIRONMENT_STARTED account=eve count=1"

proof=/mnt/veyra-home/eve/.veyra-stage1-authenticated-login
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    if [ -f "$proof" ]; then
        proof_text=$("$bb" cat "$proof")
        owner=$("$bb" stat -c '%u:%g:%a' "$proof")
        [ "$proof_text" = "account=eve uid=1000 authenticated=1" ] ||
            fail "login proof has an unexpected identity: $proof_text"
        [ "$owner" = "101000:101000:600" ] ||
            fail "login proof has an unexpected mapped owner or mode: $owner"
        echo "VEYRA_STAGE1_AUTH_HOME_VOLUME_PASS separate-ext4-mounted-at-home"
        echo "VEYRA_STAGE1_AUTH_LOGIN_QEMU_SUCCESS account=eve uid=1000 outer-uid=101000"
        "$bb" sync
        cleanup
        "$bb" poweroff -f || :
        exit 0
    fi
    "$bb" sleep 1
done
fail "named authenticated login proof did not appear"
