#!/bin/sh
# Disposable QEMU initramfs for generic manifest provisioning plus named login.
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
    if [ -b /dev/vda ] && [ -b /dev/vdb ] && [ -b /dev/vdc ]; then
        disk_ready=1
        break
    fi
    "$bb" sleep 1
done
[ "$disk_ready" -eq 1 ] || fail "system, user-store or home block device unavailable"
"$bb" mount -t ext4 -o rw /dev/vda /newroot ||
    fail "could not mount disk-backed system root on /dev/vda"
[ -x /newroot/sbin/init ] || fail "disk-backed system root lacks Alpine init"
"$bb" mkdir -p /newroot/var/lib/veyra-user-store \
    /newroot/mnt/veyra-user /newroot/mnt/veyra-home \
    /newroot/proc /newroot/sys /newroot/dev/pts /newroot/run /newroot/tmp
"$bb" mount -t ext4 -o rw /dev/vdb /newroot/var/lib/veyra-user-store ||
    fail "could not mount persistent generic user store on /dev/vdb"
"$bb" mount -t ext4 -o rw /dev/vdc /newroot/mnt/veyra-home ||
    fail "could not mount separate persistent home volume on /dev/vdc"
"$bb" mount -t proc proc /newroot/proc
"$bb" mount -t sysfs sysfs /newroot/sys
"$bb" mount -t devtmpfs devtmpfs /newroot/dev
"$bb" mkdir -p /newroot/dev/pts
"$bb" mount -t devpts devpts /newroot/dev/pts
"$bb" mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /newroot/run
"$bb" mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /newroot/tmp
echo "VEYRA_STAGE1_MANIFEST_AUTH_DISKS_READY system=/dev/vda store=/dev/vdb home=/dev/vdc"
exec "$bb" switch_root /newroot /sbin/init
