#!/bin/sh
# Disposable QEMU only. The outer system-side init owns the disk and manager.
set -eu
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mkdir -p /dev/pts /run /tmp /mnt/veyra-user /mnt/veyra-stage1-bootstrap
/bin/busybox mount -t devpts devpts /dev/pts
/bin/busybox mount -t tmpfs -o mode=0755 tmpfs /run
/bin/busybox mount -t tmpfs tmpfs /tmp
exec </dev/console >/dev/console 2>&1
/bin/busybox modprobe virtio_pci 2>/dev/null || :
/bin/busybox modprobe virtio_blk 2>/dev/null || :
/bin/busybox modprobe ext4 2>/dev/null || :
disk_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -b /dev/vda ]; then disk_ready=1; break; fi
    /bin/busybox sleep 1
done
if [ "$disk_ready" -ne 1 ]; then
    echo 'VEYRA_STAGE1_FAILURE: disposable /dev/vda unavailable'
    /bin/busybox poweroff -f
fi
if ! /bin/busybox mount -t ext4 -o rw /dev/vda /mnt/veyra-user; then
    echo 'VEYRA_STAGE1_FAILURE: disposable ext4 mount failed'
    /bin/busybox poweroff -f
fi
expected=1
for item in $(/bin/busybox cat /proc/cmdline); do
    case "$item" in
        veyra_stage1_expect=*) expected=$(printf '%s' "$item" | /bin/busybox cut -d= -f2) ;;
    esac
done
if [ "$expected" -lt 1 ] || [ "$expected" -gt 2 ]; then
    echo 'VEYRA_STAGE1_FAILURE: expected QEMU run must be 1 or 2'
    /bin/busybox poweroff -f
fi
echo "VEYRA_STAGE1_OUTER_INIT: starting lifecycle manager, QEMU boot $expected"

manager_pid=0
cleanup() {
    if [ "$manager_pid" -gt 0 ]; then
        /host-supervisor stop >/dev/null 2>&1 || :
        /bin/busybox kill -TERM "$manager_pid" 2>/dev/null || :
        wait "$manager_pid" 2>/dev/null || :
    fi
}
fail() {
    echo "VEYRA_STAGE1_FAILURE: $*"
    /bin/busybox sync
    /bin/busybox poweroff -f
    exit 1
}
trap cleanup EXIT INT TERM

/host-supervisor serve /mnt/veyra-user &
manager_pid=$!
manager_ready=0
manager_status=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if manager_status=$(/host-supervisor status 2>/dev/null); then
        manager_ready=1
        break
    fi
    /bin/busybox sleep 1
done
if [ "$manager_ready" -ne 1 ] || [ "$manager_status" != "STOPPED" ]; then
    fail 'system-side manager did not enter STOPPED state'
fi

/host-supervisor test-inode-guard || fail 'rootfs inode identity guard self-test failed'

# Require a distinct persistent mount with no user-controlled nested mounts.
bad_mount=/mnt/veyra-user/.veyra-invalid-mount-probe
/bin/busybox mkdir -p "$bad_mount"
/bin/busybox chown 300000:300000 "$bad_mount"
/bin/busybox mount -t tmpfs tmpfs "$bad_mount"
if output=$(/host-supervisor start 2>&1); then
    fail 'manager accepted a nested user-rootfs mount'
fi
/bin/busybox umount "$bad_mount"
/bin/busybox rmdir "$bad_mount"
case "$output" in
    *'rootfs must be one mount with no child mounts'*) ;;
    *) fail "unexpected nested mount probe result: $output" ;;
esac
echo 'VEYRA_STAGE1_ROOTFS_REJECT_NESTED_MOUNT'

# Reject an on-disk inode owned by initial-namespace root before any namespace
# is launched. This guards against accidental or unsafe rootfs provisioning.
bad_owner=/mnt/veyra-user/.veyra-invalid-owner-probe
/bin/busybox touch "$bad_owner"
/bin/busybox chown 0:0 "$bad_owner"
if output=$(/host-supervisor start 2>&1); then
    fail 'manager accepted an unmapped outside-root-owned rootfs file'
fi
case "$output" in
    *'entry owner lies outside mapped UID/GID range'*) ;;
    *) fail "unexpected owner probe result: $output" ;;
esac
/bin/busybox rm -f "$bad_owner"
echo 'VEYRA_STAGE1_ROOTFS_REJECT_UNMAPPED_OWNER'

# Block devices are never accepted from the user-owned persistent rootfs.
/bin/busybox mknod -m 0600 /mnt/veyra-user/dev/.veyra-invalid-block b 8 0
/bin/busybox chown 300000:300000 /mnt/veyra-user/dev/.veyra-invalid-block
if output=$(/host-supervisor start 2>&1); then
    fail 'manager accepted a block device in the user rootfs'
fi
case "$output" in
    *'unsupported special file or device'*) ;;
    *) fail "unexpected block-device probe result: $output" ;;
esac
/bin/busybox rm -f /mnt/veyra-user/dev/.veyra-invalid-block
echo 'VEYRA_STAGE1_ROOTFS_REJECT_BLOCK_DEVICE'

# Only the explicitly mapped, test-only sudo binary may retain setuid.
bad_suid=/mnt/veyra-user/home/veyrauser/.veyra-invalid-suid-probe
/bin/busybox touch "$bad_suid"
/bin/busybox chown 300000:300000 "$bad_suid"
/bin/busybox chmod 4755 "$bad_suid"
if output=$(/host-supervisor start 2>&1); then
    fail 'manager accepted an unexpected setuid executable'
fi
case "$output" in
    *'unexpected setuid/setgid file'*) ;;
    *) fail "unexpected setuid probe result: $output" ;;
esac
/bin/busybox rm -f "$bad_suid"
echo 'VEYRA_STAGE1_ROOTFS_REJECT_UNEXPECTED_SUID'

# An init symlink must not resolve through the system-side root. The host
# target exists, but RESOLVE_IN_ROOT must clamp it to the user rootfs.
init_backup=/mnt/veyra-user/.veyra-stage1-init-backup
init_escape=/tmp/.veyra-stage1-init-escape
/bin/busybox rm -f "$init_backup" "$init_escape"
/bin/busybox printf '#!/bin/sh\nexit 0\n' > "$init_escape"
/bin/busybox chmod 0755 "$init_escape"
/bin/busybox mv /mnt/veyra-user/sbin/init "$init_backup"
/bin/busybox ln -s ../../../../tmp/.veyra-stage1-init-escape \
    /mnt/veyra-user/sbin/init
/bin/busybox chown -h 300000:300000 /mnt/veyra-user/sbin/init
if output=$(/host-supervisor start 2>&1); then
    fail 'manager resolved /sbin/init outside the user rootfs'
fi
case "$output" in
    *'rootfs does not contain an executable /sbin/init'*) ;;
    *) fail "unexpected init-escape probe result: $output" ;;
esac
/bin/busybox rm /mnt/veyra-user/sbin/init
/bin/busybox mv "$init_backup" /mnt/veyra-user/sbin/init
/bin/busybox rm -f "$init_escape"
echo 'VEYRA_STAGE1_ROOTFS_REJECT_INIT_ESCAPE'

first=$(/host-supervisor start)
case "$first" in RUNNING\ pid=*\ count=*) ;; *) fail "first start failed: $first" ;; esac
echo "VEYRA_STAGE1_FIRST_RUNNING $first"
status=$(/host-supervisor status)
if [ "$status" != "$first" ]; then fail "status disagreed with running start: $status"; fi
echo "VEYRA_STAGE1_STATUS_RUNNING $status"
stopped=$(/host-supervisor stop)
if [ "$stopped" != "STOPPED" ]; then fail "stop failed: $stopped"; fi
status=$(/host-supervisor status)
if [ "$status" != "STOPPED" ]; then fail "status after stop was $status"; fi
echo 'VEYRA_STAGE1_STATUS_STOPPED'

second=$(/host-supervisor start)
case "$second" in RUNNING\ pid=*\ count=*) ;; *) fail "restart failed: $second" ;; esac
user_pid=$(/bin/busybox printf '%s\n' "$second" | /bin/busybox cut -d' ' -f2 | /bin/busybox cut -d= -f2)
second_count=$(/bin/busybox printf '%s\n' "$second" | /bin/busybox cut -d' ' -f3 | /bin/busybox cut -d= -f2)
expected_count=$((expected * 3 - 1))
if [ "$second_count" -ne "$expected_count" ]; then
    fail "persistent boot counter was $second_count, expected $expected_count"
fi
/bin/busybox kill -KILL "$user_pid"
crash_seen=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    status=$(/host-supervisor status)
    case "$status" in FAILED*) crash_seen=1; break ;; esac
    /bin/busybox sleep 1
done
if [ "$crash_seen" -ne 1 ]; then fail 'manager did not detect nested PID 1 crash'; fi
echo "VEYRA_STAGE1_LIFECYCLE_PASS boot=$expected starts=2 final-count=$second_count crash=detected"

# A manager crash must not leave its user PID namespace running unattended.
third=$(/host-supervisor start)
case "$third" in RUNNING\ pid=*\ count=*) ;; *) fail "third start failed: $third" ;; esac
user_pid=$(/bin/busybox printf '%s\n' "$third" | /bin/busybox cut -d' ' -f2 | /bin/busybox cut -d= -f2)
third_count=$(/bin/busybox printf '%s\n' "$third" | /bin/busybox cut -d' ' -f3 | /bin/busybox cut -d= -f2)
expected_third_count=$((expected * 3))
if [ "$third_count" -ne "$expected_third_count" ]; then
    fail "manager-crash test boot counter was $third_count, expected $expected_third_count"
fi
/bin/busybox kill -KILL "$manager_pid"
wait "$manager_pid" 2>/dev/null || :
manager_pid=0
user_gone=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    process_state=""
    if [ -r "/proc/$user_pid/stat" ]; then
        process_state=$(/bin/busybox sed 's/^.*) //' "/proc/$user_pid/stat" | /bin/busybox cut -d' ' -f1)
    fi
    case "$process_state" in
        Z|X) user_gone=1; break ;;
    esac
    if ! /bin/busybox kill -0 "$user_pid" 2>/dev/null; then user_gone=1; break; fi
    /bin/busybox sleep 1
done
if [ "$user_gone" -ne 1 ]; then
    fail "user PID 1 $user_pid survived system-side manager death"
fi
echo "VEYRA_STAGE1_MANAGER_DEATH_CLEANUP_PASS boot=$expected count=$third_count environment=stopped"

# Restart also exercises stale control-socket cleanup after an unclean exit.
/host-supervisor serve /mnt/veyra-user &
manager_pid=$!
manager_ready=0
manager_status=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if manager_status=$(/host-supervisor status 2>/dev/null); then
        manager_ready=1
        break
    fi
    /bin/busybox sleep 1
done
if [ "$manager_ready" -ne 1 ] || [ "$manager_status" != "STOPPED" ]; then
    fail "manager did not recover cleanly after crash: $manager_status"
fi
echo 'VEYRA_STAGE1_MANAGER_RECOVERY_PASS state=STOPPED stale-socket=cleared'
echo "VEYRA_STAGE1_QEMU_SUCCESS: user environment lifecycle and persistence boot $expected"
/bin/busybox sync
/bin/busybox poweroff -f
