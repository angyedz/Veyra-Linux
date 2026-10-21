#!/bin/sh
# Disposable Alpine initramfs for SnapCore ext4 OS and personal-data volumes.
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
    if [ -b /dev/vda ] && [ -b /dev/vdb ]; then disk_ready=1; break; fi
    "$BB" sleep 1
done
if [ "$disk_ready" -ne 1 ]; then
    echo 'VEYRA_SNAPCORE_FAILURE: QEMU root/home virtio block devices unavailable'
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
mount_root_rw() {
    "$BB" mount -t ext4 -o noatime /dev/vda /mnt/snapcore ||
        fail 'could not mount the SnapCore-backed ext4 user-root volume'
}
mount_home_rw() {
    "$BB" mkdir -p /mnt/snapcore/home
    "$BB" mount -t ext4 -o noatime /dev/vdb /mnt/snapcore/home ||
        fail 'could not mount the separately snapshotted ext4 /home volume'
}
unmount_both() {
    "$BB" sync
    "$BB" umount /mnt/snapcore/home ||
        fail 'could not cleanly unmount the ext4 /home volume'
    "$BB" umount /mnt/snapcore ||
        fail 'could not cleanly unmount the ext4 user-root volume'
}

case "$phase" in
    baseline)
        /sbin/mkfs.ext4 -F -q -L VEYRA_USER_ROOT /dev/vda ||
            fail 'mkfs.ext4 failed on the SnapCore user-root QEMU disk'
        /sbin/mkfs.ext4 -F -q -L VEYRA_USER_HOME /dev/vdb ||
            fail 'mkfs.ext4 failed on the separate SnapCore /home QEMU disk'
        mount_root_rw
        mount_home_rw
        "$BB" mkdir -p /mnt/snapcore/user-root /mnt/snapcore/home/veyrauser/Documents
        "$BB" printf '%s\n' 'baseline-user-root' \
            > /mnt/snapcore/user-root/state.txt
        "$BB" printf '%s\n' 'personal-file-before-checkpoint' \
            > /mnt/snapcore/home/veyrauser/Documents/recovery-note.txt
        unmount_both
        echo 'VEYRA_SNAPCORE_TWO_VOLUME_BASELINE_PASS'
        ;;
    mutate)
        mount_root_rw
        mount_home_rw
        [ "$("$BB" cat /mnt/snapcore/user-root/state.txt)" = 'baseline-user-root' ] ||
            fail 'baseline user-root data was not present before mutation'
        [ "$("$BB" cat /mnt/snapcore/home/veyrauser/Documents/recovery-note.txt)" = \
            'personal-file-before-checkpoint' ] ||
            fail 'baseline personal file was not present before mutation'
        "$BB" rm -f /mnt/snapcore/user-root/state.txt
        "$BB" printf '%s\n' 'mutated-user-root' \
            > /mnt/snapcore/user-root/state-mutated.txt
        "$BB" printf '%s\n' 'must-disappear-after-root-rollback' \
            > /mnt/snapcore/user-root/mutation-only.txt
        # This destructive recursive delete stays inside a disposable QEMU
        # guest but crosses into the separately mounted personal-data volume.
        # Root-only rollback must leave the resulting current /home untouched.
        "$BB" rm -rf /mnt/snapcore/home/veyrauser/Documents
        "$BB" mkdir -p /mnt/snapcore/home/veyrauser/Documents
        "$BB" printf '%s\n' 'new-personal-file-after-checkpoint' \
            > /mnt/snapcore/home/veyrauser/Documents/post-checkpoint.txt
        unmount_both
        echo 'VEYRA_SNAPCORE_TWO_VOLUME_MUTATION_PASS'
        ;;
    verify-root)
        /sbin/e2fsck -f -n /dev/vda ||
            fail 'ext4 user-root consistency check failed after root rollback'
        /sbin/e2fsck -f -n /dev/vdb ||
            fail 'ext4 /home consistency check failed after root-only rollback'
        "$BB" mount -t ext4 -o ro,noload /dev/vda /mnt/snapcore ||
            fail 'could not mount the restored user-root volume read-only'
        "$BB" mount -t ext4 -o ro,noload /dev/vdb /mnt/snapcore/home ||
            fail 'could not mount current /home volume read-only'
        [ "$("$BB" cat /mnt/snapcore/user-root/state.txt)" = 'baseline-user-root' ] ||
            fail 'root-only rollback did not restore the baseline user-root data'
        [ ! -e /mnt/snapcore/user-root/mutation-only.txt ] ||
            fail 'root-only rollback retained its post-checkpoint file'
        [ ! -e /mnt/snapcore/user-root/state-mutated.txt ] ||
            fail 'root-only rollback retained its mutated replacement file'
        [ ! -e /mnt/snapcore/home/veyrauser/Documents/recovery-note.txt ] ||
            fail 'root-only rollback unexpectedly rewound the separately mounted /home'
        [ "$("$BB" cat /mnt/snapcore/home/veyrauser/Documents/post-checkpoint.txt)" = \
            'new-personal-file-after-checkpoint' ] ||
            fail 'root-only rollback did not preserve the current /home contents'
        "$BB" umount /mnt/snapcore/home || fail 'could not unmount verified /home volume'
        "$BB" umount /mnt/snapcore || fail 'could not unmount verified user-root volume'
        echo 'VEYRA_SNAPCORE_ROOT_ONLY_RESTORE_HOME_PRESERVED_PASS'
        ;;
    destroy-root)
        mount_root_rw
        mount_home_rw
        [ "$("$BB" cat /mnt/snapcore/user-root/state.txt)" = 'baseline-user-root' ] ||
            fail 'baseline user-root file was not present before recursive root deletion'
        [ "$("$BB" cat /mnt/snapcore/home/veyrauser/Documents/post-checkpoint.txt)" = \
            'new-personal-file-after-checkpoint' ] ||
            fail 'current personal file was not present before recursive root deletion'
        # The /home filesystem is mounted separately. Delete every entry from
        # the user-root ext4 tree while leaving that mounted personal volume in
        # place, matching the cross-mount failure boundary called out in the
        # recovery contract.
        for entry in /mnt/snapcore/* /mnt/snapcore/.[!.]* /mnt/snapcore/..?*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            [ "$entry" = '/mnt/snapcore/home' ] || "$BB" rm -rf "$entry"
        done
        for entry in /mnt/snapcore/* /mnt/snapcore/.[!.]* /mnt/snapcore/..?*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            [ "$entry" = '/mnt/snapcore/home' ] ||
                fail "recursive root deletion left an entry: $entry"
        done
        [ ! -e /mnt/snapcore/user-root/state.txt ] ||
            fail 'recursive root deletion left the baseline root file'
        [ "$("$BB" cat /mnt/snapcore/home/veyrauser/Documents/post-checkpoint.txt)" = \
            'new-personal-file-after-checkpoint' ] ||
            fail 'recursive root deletion damaged the separately mounted /home file'
        unmount_both
        /sbin/e2fsck -f -n /dev/vda ||
            fail 'ext4 user-root consistency check failed after recursive deletion'
        /sbin/e2fsck -f -n /dev/vdb ||
            fail 'ext4 /home consistency check failed after recursive root deletion'
        echo 'VEYRA_SNAPCORE_FULL_USER_ROOT_DELETE_PASS'
        ;;
    verify-root-after-delete)
        /sbin/e2fsck -f -n /dev/vda ||
            fail 'ext4 user-root consistency check failed after full-root rollback'
        /sbin/e2fsck -f -n /dev/vdb ||
            fail 'ext4 /home consistency check failed after full-root rollback'
        "$BB" mount -t ext4 -o ro,noload /dev/vda /mnt/snapcore ||
            fail 'could not mount restored user-root volume read-only after full deletion'
        "$BB" mount -t ext4 -o ro,noload /dev/vdb /mnt/snapcore/home ||
            fail 'could not mount current /home volume after full-root rollback'
        [ "$("$BB" cat /mnt/snapcore/user-root/state.txt)" = 'baseline-user-root' ] ||
            fail 'full-root rollback did not restore the baseline user-root file'
        [ ! -e /mnt/snapcore/user-root/state-mutated.txt ] ||
            fail 'full-root rollback retained a mutated user-root file'
        [ ! -e /mnt/snapcore/user-root/mutation-only.txt ] ||
            fail 'full-root rollback retained a post-checkpoint user-root file'
        [ ! -e /mnt/snapcore/home/veyrauser/Documents/recovery-note.txt ] ||
            fail 'full-root rollback unexpectedly rewound the separately mounted /home'
        [ "$("$BB" cat /mnt/snapcore/home/veyrauser/Documents/post-checkpoint.txt)" = \
            'new-personal-file-after-checkpoint' ] ||
            fail 'full-root rollback did not preserve the newer current /home file'
        "$BB" umount /mnt/snapcore/home || fail 'could not unmount verified /home after full-root rollback'
        "$BB" umount /mnt/snapcore || fail 'could not unmount verified root after full-root rollback'
        echo 'VEYRA_SNAPCORE_FULL_ROOT_RESTORE_HOME_PRESERVED_PASS'
        ;;
    verify-home)
        /sbin/e2fsck -f -n /dev/vda ||
            fail 'ext4 user-root consistency check failed after separate /home restore'
        /sbin/e2fsck -f -n /dev/vdb ||
            fail 'ext4 /home consistency check failed after its separate restore'
        "$BB" mount -t ext4 -o ro,noload /dev/vda /mnt/snapcore ||
            fail 'could not mount user-root volume read-only'
        "$BB" mount -t ext4 -o ro,noload /dev/vdb /mnt/snapcore/home ||
            fail 'could not mount restored /home volume read-only'
        [ "$("$BB" cat /mnt/snapcore/user-root/state.txt)" = 'baseline-user-root' ] ||
            fail 'separate /home rollback changed the restored user-root volume'
        [ ! -e /mnt/snapcore/user-root/mutation-only.txt ] ||
            fail 'separate /home rollback changed user-root post-checkpoint state'
        [ ! -e /mnt/snapcore/user-root/state-mutated.txt ] ||
            fail 'separate /home rollback changed restored user-root state'
        [ "$("$BB" cat /mnt/snapcore/home/veyrauser/Documents/recovery-note.txt)" = \
            'personal-file-before-checkpoint' ] ||
            fail 'explicit /home rollback did not restore the earlier personal file'
        [ ! -e /mnt/snapcore/home/veyrauser/Documents/post-checkpoint.txt ] ||
            fail 'explicit /home rollback retained its post-checkpoint file'
        "$BB" umount /mnt/snapcore/home || fail 'could not unmount restored /home volume'
        "$BB" umount /mnt/snapcore || fail 'could not unmount restored user-root volume'
        echo 'VEYRA_SNAPCORE_SEPARATE_HOME_RESTORE_PASS'
        ;;
    *)
        fail "unknown QEMU phase: $phase"
        ;;
esac

"$BB" sync
"$BB" poweroff -f
