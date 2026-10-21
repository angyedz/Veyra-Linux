#!/bin/sh
# Disposable Alpine initramfs used only by the SnapCore/ext4 QEMU test.
set -eu
BB=/bin/busybox
"$BB" mount -t proc proc /proc
"$BB" mount -t sysfs sysfs /sys
"$BB" mount -t devtmpfs devtmpfs /dev
"$BB" mkdir -p /dev/pts /run /tmp /mnt/snapcore
"$BB" mount -t devpts devpts /dev/pts
"$BB" mount -t tmpfs -o mode=0755 tmpfs /run
"$BB" mount -t tmpfs -o mode=1777 tmpfs /tmp
exec </dev/console >/dev/console 2>&1

"$BB" modprobe virtio_pci 2>/dev/null || :
"$BB" modprobe virtio_blk 2>/dev/null || :
"$BB" modprobe ext4 2>/dev/null || :
disk_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -b /dev/vda ]; then disk_ready=1; break; fi
    "$BB" sleep 1
done
if [ "$disk_ready" -ne 1 ]; then
    echo 'VEYRA_SNAPCORE_FAILURE: QEMU virtio block device unavailable'
    "$BB" poweroff -f
    exit 1
fi

phase=
for item in $("$BB" cat /proc/cmdline); do
    case "$item" in
        veyra_snapcore_phase=*) phase=${item#*=} ;;
    esac
done

fail() {
    echo "VEYRA_SNAPCORE_FAILURE: $*"
    "$BB" sync
    "$BB" poweroff -f
    exit 1
}
mount_rw() {
    "$BB" mount -t ext4 -o noatime /dev/vda /mnt/snapcore ||
        fail 'could not mount ext4 test volume read-write'
}
unmount() {
    "$BB" sync
    "$BB" umount /mnt/snapcore || fail 'could not cleanly unmount ext4 test volume'
}

case "$phase" in
    baseline)
        /sbin/mkfs.ext4 -F -q -L VEYRA_SNAPCORE /dev/vda ||
            fail 'mkfs.ext4 failed on the SnapCore-backed QEMU disk'
        mount_rw
        "$BB" mkdir -p /mnt/snapcore/user-root
        "$BB" printf '%s\n' 'baseline-user-root'             > /mnt/snapcore/user-root/state.txt
        unmount
        echo 'VEYRA_SNAPCORE_BASELINE_PASS'
        ;;
    mutate)
        mount_rw
        [ "$("$BB" cat /mnt/snapcore/user-root/state.txt)" = 'baseline-user-root' ] ||
            fail 'baseline data was not present before mutation'
        "$BB" printf '%s\n' 'mutated-user-root'             > /mnt/snapcore/user-root/state.txt
        "$BB" printf '%s\n' 'must-disappear-after-rollback'             > /mnt/snapcore/user-root/mutation-only.txt
        unmount
        echo 'VEYRA_SNAPCORE_MUTATION_PASS'
        ;;
    verify)
        /sbin/e2fsck -f -n /dev/vda ||
            fail 'ext4 consistency check failed after rollback'
        "$BB" mount -t ext4 -o ro,noload /dev/vda /mnt/snapcore ||
            fail 'could not mount restored ext4 test volume read-only'
        [ "$("$BB" cat /mnt/snapcore/user-root/state.txt)" = 'baseline-user-root' ] ||
            fail 'rollback did not restore the baseline contents'
        [ ! -e /mnt/snapcore/user-root/mutation-only.txt ] ||
            fail 'rollback retained a file created after the checkpoint'
        "$BB" umount /mnt/snapcore || fail 'could not unmount verified ext4 volume'
        echo 'VEYRA_SNAPCORE_ROLLBACK_EXT4_PASS'
        ;;
    *)
        fail "unknown QEMU phase: $phase"
        ;;
esac

"$BB" sync
"$BB" poweroff -f
