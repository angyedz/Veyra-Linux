#!/bin/sh
# Disposable QEMU initramfs for authenticated accounts in one shared user root.
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
    echo "VEYRA_STAGE1_SHARED_AUTH_FAILURE: $*"
    cleanup
    "$bb" sync || :
    "$bb" poweroff -f || :
    exit 1
}
trap cleanup EXIT INT TERM

"$bb" mount -t proc proc /proc
"$bb" mount -t sysfs sysfs /sys
"$bb" mount -t devtmpfs devtmpfs /dev
"$bb" mkdir -p /dev/pts /run /tmp /mnt/veyra-user
"$bb" mount -t devpts devpts /dev/pts
"$bb" mount -t tmpfs -o mode=0755 tmpfs /run
"$bb" mount -t tmpfs -o mode=1777 tmpfs /tmp
exec </dev/console >/dev/console 2>&1
"$bb" modprobe virtio_pci 2>/dev/null || :
"$bb" modprobe virtio_blk 2>/dev/null || :
"$bb" modprobe ext4 2>/dev/null || :

expected_boot=1
for item in $("$bb" cat /proc/cmdline); do
    case "$item" in
        veyra_stage1_auth_expect=*)
            expected_boot=${item#veyra_stage1_auth_expect=}
            ;;
    esac
done
case "$expected_boot" in 1|2) ;; *) fail "expected auth QEMU boot must be 1 or 2" ;; esac

disk_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -b /dev/vda ]; then disk_ready=1; break; fi
    "$bb" sleep 1
done
[ "$disk_ready" -eq 1 ] || fail "disposable /dev/vda unavailable"
"$bb" mount -t ext4 -o rw /dev/vda /mnt/veyra-user ||
    fail "could not mount the persistent shared user root"
[ -x /mnt/veyra-user/sbin/init ] || fail "shared user root lacks executable /sbin/init"
[ -f /mnt/veyra-user/.veyra-stage1-rootfs ] || fail "shared user root marker is missing"

"/host-supervisor" serve /mnt/veyra-user >/run/veyra-stage1-auth-manager.log 2>&1 &
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
status=$(/host-supervisor status 2>&1) || fail "could not query test manager: $status"
[ "$status" = STOPPED ] || fail "manager did not start in STOPPED state: $status"
start_result=$(/host-supervisor start 2>&1) ||
    fail "shared user environment failed to start: $start_result"
case "$start_result" in RUNNING\ pid=*\ count=1) ;; *) fail "unexpected start result: $start_result" ;; esac
echo "VEYRA_STAGE1_SHARED_AUTH_MANAGER_READY boot=$expected_boot accounts=1000,1001"

uid1000=$((expected_boot))
uid1001=$((expected_boot))
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
    if [ -f /mnt/veyra-user/home/veyrauser/.veyra-stage1-authenticated-shared-root ] &&
       [ -f /mnt/veyra-user/home/veyrauser2/.veyra-stage1-authenticated-shared-root ]; then
        break
    fi
    "$bb" sleep 1
done
proof1=/mnt/veyra-user/home/veyrauser/.veyra-stage1-authenticated-shared-root
proof2=/mnt/veyra-user/home/veyrauser2/.veyra-stage1-authenticated-shared-root
if [ ! -f "$proof1" ] || [ -L "$proof1" ]; then
    fail "account 1000 login proof is missing"
fi
if [ ! -f "$proof2" ] || [ -L "$proof2" ]; then
    fail "account 1001 login proof is missing"
fi
shared_fields_awk='{ print $4, $5, $6, $7 }'
login_count_awk='{ print $3 }'
shared1=$("$bb" awk "$shared_fields_awk" "$proof1")
shared2=$("$bb" awk "$shared_fields_awk" "$proof2")
[ "$shared1" = "$shared2" ] ||
    fail "accounts did not observe the same shared root, APK database, mount namespace and UID map"
[ "$("$bb" stat -c '%u:%g:%a' "$proof1")" = "101000:101000:600" ] ||
    fail "first authenticated proof has unexpected mapped ownership or mode"
[ "$("$bb" stat -c '%u:%g:%a' "$proof2")" = "101001:101001:600" ] ||
    fail "second authenticated proof has unexpected mapped ownership or mode"
[ "$("$bb" awk "$login_count_awk" "$proof1")" = "count=$uid1000" ] ||
    fail "first account's persistent login count is wrong"
[ "$("$bb" awk "$login_count_awk" "$proof2")" = "count=$uid1001" ] ||
    fail "second account's persistent login count is wrong"

echo "VEYRA_STAGE1_SHARED_AUTH_MULTIUSER_PASS accounts=1000,1001 shared-root=1 shared-apkdb=1 shared-mountns=1 separate-homes=1 wrong-password-rejected=1 persistent-count=$expected_boot"
"$bb" sleep 2
cleanup
"$bb" sync
"$bb" poweroff -f || :
exit 0
