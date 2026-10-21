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
echo "VEYRA_STAGE1_OUTER_INIT: starting system OpenRC, QEMU boot $expected"

manager_pid=0
cleanup() {
    /sbin/rc-service veyra-stage1-system-manager stop >/dev/null 2>&1 || :
}
fail() {
    echo "VEYRA_STAGE1_FAILURE: $*"
    /bin/busybox sync
    /bin/busybox poweroff -f
    exit 1
}
verify_autologin() {
    expected_count=$1
    actual=""
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        actual=$(/bin/busybox cat /mnt/veyra-user/home/veyrauser/.veyra-stage1-autologin 2>/dev/null || :)
        if [ "$actual" = "uid=1000 count=$expected_count" ]; then
            echo "VEYRA_STAGE1_AUTOLOGIN_PASS uid=1000 count=$expected_count"
            return 0
        fi
        /bin/busybox sleep 1
    done
    fail "user environment did not autologin as UID 1000 with count $expected_count (got: $actual)"
}
trap cleanup EXIT INT TERM

/sbin/openrc sysinit || fail 'system OpenRC sysinit failed'
/sbin/openrc boot || fail 'system OpenRC boot failed'
/sbin/openrc default || fail 'system OpenRC default runlevel failed'
manager_status=$(/host-supervisor status 2>/dev/null || :)
case "$manager_status" in
    RUNNING\ pid=*\ count=*) ;;
    *) fail "system OpenRC did not auto-start the user environment: $manager_status" ;;
esac
boot_login_count=$(((expected - 1) * 5 + 1))
case "$manager_status" in
    *"count=$boot_login_count") ;;
    *) fail "system OpenRC boot count did not match persistent login state: $manager_status" ;;
esac
verify_autologin "$boot_login_count"
manager_pid=$(/bin/busybox cat /run/veyra-user-manager.pid 2>/dev/null || :)
case "$manager_pid" in
    ''|*[!0-9]*) fail "system OpenRC did not write a valid manager pidfile: $manager_pid" ;;
esac
echo "VEYRA_STAGE1_SYSTEM_OPENRC_STARTED pid=$manager_pid count=$boot_login_count"
stopped=$(/host-supervisor stop)
if [ "$stopped" != "STOPPED" ]; then fail "could not stop system-OpenRC autostarted environment: $stopped"; fi


/host-supervisor test-inode-guard || fail 'rootfs inode identity guard self-test failed'

# Require a distinct persistent mount with no user-controlled nested mounts.
bad_mount=/mnt/veyra-user/.veyra-invalid-mount-probe
/bin/busybox mkdir -p "$bad_mount"
/bin/busybox chown 100000:100000 "$bad_mount"
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
/bin/busybox chown 100000:100000 /mnt/veyra-user/dev/.veyra-invalid-block
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
/bin/busybox chown 100000:100000 "$bad_suid"
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
/bin/busybox chown -h 100000:100000 /mnt/veyra-user/sbin/init
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
verify_autologin "$(( (expected - 1) * 5 + 2 ))"
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
expected_count=$(( (expected - 1) * 5 + 3 ))
if [ "$second_count" -ne "$expected_count" ]; then
    fail "persistent boot counter was $second_count, expected $expected_count"
fi
verify_autologin "$(( (expected - 1) * 5 + 3 ))"
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
expected_third_count=$(( (expected - 1) * 5 + 4 ))
if [ "$third_count" -ne "$expected_third_count" ]; then
    fail "manager-crash test boot counter was $third_count, expected $expected_third_count"
fi
verify_autologin "$expected_third_count"
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

# Restart through system OpenRC also exercises stale socket and pidfile recovery.
/sbin/rc-service veyra-stage1-system-manager restart || fail 'OpenRC could not restart the manager'
manager_status=$(/host-supervisor status 2>/dev/null || :)
manager_pid=$(/bin/busybox cat /run/veyra-user-manager.pid 2>/dev/null || :)
case "$manager_pid" in ''|*[!0-9]*) fail "OpenRC restart did not write a valid manager pidfile: $manager_pid" ;; esac
recovery_count=$((expected * 5))
case "$manager_status" in
    *"count=$recovery_count") ;;
    *) fail "OpenRC restart did not auto-start user environment: $manager_status" ;;
esac
verify_autologin "$recovery_count"
echo "VEYRA_STAGE1_MANAGER_RECOVERY_PASS state=RUNNING autologin-count=$recovery_count stale-socket=cleared"
echo "VEYRA_STAGE1_QEMU_SUCCESS: user environment lifecycle and persistence boot $expected"
/bin/busybox sync
/bin/busybox poweroff -f
