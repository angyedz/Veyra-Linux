#!/bin/sh
# Disposable QEMU only. This outer init stays independent of the nested
# Alpine BusyBox PID1 / OpenRC and owns a persistent ext4 user-root disk.
set -eu
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mkdir -p /dev/pts /run /tmp /mnt/veyra-user /mnt/veyra-stage1-bootstrap
/bin/busybox mount -t devpts devpts /dev/pts
/bin/busybox mount -t tmpfs tmpfs /run
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
echo "VEYRA_STAGE1_OUTER_INIT: starting separate user rootfs, boot $expected"
if /host-supervisor /mnt/veyra-user "$expected"; then
    echo "VEYRA_STAGE1_QEMU_SUCCESS: user OpenRC persistent boot $expected"
else
    echo 'VEYRA_STAGE1_QEMU_FAILURE: nested OpenRC did not become ready'
fi
/bin/busybox sync
/bin/busybox poweroff -f
