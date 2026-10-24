#!/bin/sh
# Test-only initramfs for a disk-backed Alpine system root plus user rootfs.
set -eu
bb=/bin/busybox
fail() {
    echo "VEYRA_STAGE1_FAILURE: $*"
    "$bb" sync || :
    "$bb" poweroff -f || :
    exit 1
}
"$bb" mount -t proc proc /proc
"$bb" mount -t sysfs sysfs /sys
"$bb" mount -t devtmpfs devtmpfs /dev
"$bb" mkdir -p /dev/pts /run /tmp /newroot
"$bb" mount -t devpts devpts /dev/pts
"$bb" mount -t tmpfs -o mode=0755 tmpfs /run
"$bb" mount -t tmpfs -o mode=1777 tmpfs /tmp
exec </dev/console >/dev/console 2>&1
"$bb" modprobe virtio_pci 2>/dev/null || :
"$bb" modprobe virtio_blk 2>/dev/null || :
"$bb" modprobe ext4 2>/dev/null || :
disk_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -b /dev/vda ] && [ -b /dev/vdb ]; then disk_ready=1; break; fi
    "$bb" sleep 1
done
if [ "$disk_ready" -ne 1 ]; then
    fail "system/user block devices /dev/vda and /dev/vdb unavailable"
fi
if ! "$bb" mount -t ext4 -o rw /dev/vda /newroot; then
    fail "could not mount disk-backed system root on /dev/vda"
fi
if [ ! -x /newroot/sbin/init ] || [ ! -x /newroot/sbin/openrc ]; then
    fail "disk-backed system root lacks Alpine init/OpenRC"
fi
"$bb" mkdir -p /newroot/mnt/veyra-user /newroot/proc /newroot/sys \
    /newroot/dev/pts /newroot/run /newroot/tmp
if ! "$bb" mount -t ext4 -o rw /dev/vdb /newroot/mnt/veyra-user; then
    fail "could not mount persistent user root on /dev/vdb"
fi
if [ ! -f /newroot/mnt/veyra-user/.veyra-stage1-rootfs ]; then
    fail "persistent user root marker is missing"
fi
"$bb" mount -t proc proc /newroot/proc
"$bb" mount -t sysfs sysfs /newroot/sys
"$bb" mount -t devtmpfs devtmpfs /newroot/dev
"$bb" mkdir -p /newroot/dev/pts
"$bb" mount -t devpts devpts /newroot/dev/pts
"$bb" mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /newroot/run
"$bb" mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /newroot/tmp
"$bb" printf 'system-only\n' > /newroot/run/.veyra-stage1-run-boundary
"$bb" chmod 0400 /newroot/run/.veyra-stage1-run-boundary
echo "VEYRA_STAGE1_DUAL_ROOT_MOUNTED system=/dev/vda user=/dev/vdb"
exec "$bb" switch_root /newroot /sbin/init
