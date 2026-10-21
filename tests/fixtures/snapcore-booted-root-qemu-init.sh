#!/bin/sh
# Disposable initramfs that pivots into an ext4 root exported by SnapCore.
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
    echo 'VEYRA_SNAPCORE_FAILURE: SnapCore-backed virtio root device unavailable'
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

if [ "$phase" = "prepare-root" ]; then
    /sbin/mkfs.ext4 -F -q -L VEYRA_BOOTED_ROOT /dev/vda ||
        fail 'mkfs.ext4 failed for the booted-root fixture'
    "$BB" mount -t ext4 -o noatime /dev/vda /mnt/snapcore ||
        fail 'could not mount the booted-root ext4 volume'
    "$BB" mkdir -p /mnt/snapcore/bin /mnt/snapcore/lib /mnt/snapcore/sbin \
        /mnt/snapcore/dev /mnt/snapcore/proc /mnt/snapcore/sys \
        /mnt/snapcore/run /mnt/snapcore/tmp /mnt/snapcore/root \
        /mnt/snapcore/usr/lib /mnt/snapcore/etc
    "$BB" cp /bin/busybox /mnt/snapcore/bin/busybox ||
        fail 'could not stage the test root shell'
    "$BB" cp /sbin/veyra-wipe-root /mnt/snapcore/sbin/veyra-wipe-root ||
        fail 'could not stage the static full-root deletion probe'
    if [ -e /lib/ld-musl-x86_64.so.1 ]; then
        "$BB" cp -L /lib/ld-musl-x86_64.so.1 /mnt/snapcore/lib/ld-musl-x86_64.so.1 ||
            fail 'could not stage the musl loader'
    elif [ -e /lib/ld-musl-aarch64.so.1 ]; then
        "$BB" cp -L /lib/ld-musl-aarch64.so.1 /mnt/snapcore/lib/ld-musl-aarch64.so.1 ||
            fail 'could not stage the musl loader'
    else
        fail 'the BusyBox dynamic loader was not found'
    fi
    "$BB" printf '%s\n' 'baseline-ext4-root' \
        > /mnt/snapcore/usr/lib/veyra-snapcore-root-marker
    "$BB" printf '%s\n' 'DISPOSABLE_QEMU_ROOT_V1' \
        > /mnt/snapcore/etc/veyra-snapcore-root-fixture
    "$BB" cat > /mnt/snapcore/sbin/init <<'ROOT_INIT'
#!/bin/busybox sh
set -eu
BB=/bin/busybox
exec </dev/console >/dev/console 2>&1
"$BB" mount -t proc proc /proc 2>/dev/null || :
"$BB" mount -t sysfs sysfs /sys 2>/dev/null || :
phase=
for item in $("$BB" cat /proc/cmdline); do
    case "$item" in
        veyra_snapcore_phase=*) phase=${item#*=} ;;
    esac
done
root_source=$("$BB" awk '$2 == "/" { print $1; exit }' /proc/mounts)
[ "$root_source" = "/dev/vda" ] || {
    echo "VEYRA_SNAPCORE_FAILURE: PID 1 root is not ext4 /dev/vda ($root_source)"
    "$BB" poweroff -f
    exit 1
}
case "$phase" in
    mutate-root)
        [ "$("$BB" cat /usr/lib/veyra-snapcore-root-marker)" = "baseline-ext4-root" ] || {
            echo 'VEYRA_SNAPCORE_FAILURE: booted root did not contain the checkpoint marker'
            "$BB" poweroff -f
            exit 1
        }
        "$BB" rm -rf /usr
        "$BB" printf '%s\n' 'removed-usr' > /root/veyra-mutation-marker
        echo 'VEYRA_SNAPCORE_BOOTED_ROOT_MUTATION_PASS root=/dev/vda removed=/usr'
        ;;
    delete-root)
        [ "$("$BB" cat /usr/lib/veyra-snapcore-root-marker)" = "baseline-ext4-root" ] || {
            echo 'VEYRA_SNAPCORE_FAILURE: full-root test did not start from its checkpoint'
            "$BB" poweroff -f
            exit 1
        }
        exec /sbin/veyra-wipe-root
        ;;
    verify-root)
        [ "$("$BB" cat /usr/lib/veyra-snapcore-root-marker)" = "baseline-ext4-root" ] || {
            echo 'VEYRA_SNAPCORE_FAILURE: rollback did not restore the booted ext4 root'
            "$BB" poweroff -f
            exit 1
        }
        [ ! -e /root/veyra-mutation-marker ] || {
            echo 'VEYRA_SNAPCORE_FAILURE: rollback retained the post-checkpoint mutation'
            "$BB" poweroff -f
            exit 1
        }
        echo 'VEYRA_SNAPCORE_BOOTED_ROOT_RESTORE_PASS root=/dev/vda marker=baseline mutation=absent'
        ;;
    *)
        echo "VEYRA_SNAPCORE_FAILURE: unexpected booted-root phase: $phase"
        "$BB" poweroff -f
        exit 1
        ;;
esac
"$BB" sync
"$BB" poweroff -f
ROOT_INIT
    "$BB" chmod 0755 /mnt/snapcore/sbin/init
    "$BB" sync
    "$BB" umount /mnt/snapcore ||
        fail 'could not cleanly unmount the initial ext4 root'
    echo 'VEYRA_SNAPCORE_BOOTED_ROOT_BASELINE_PASS root=/dev/vda ext4=1'
    "$BB" sync
    "$BB" poweroff -f
fi

case "$phase" in
    verify-root)
        /sbin/e2fsck -f -n /dev/vda ||
            fail 'e2fsck rejected the checkpoint-restored ext4 root'
        echo 'VEYRA_SNAPCORE_BOOTED_ROOT_E2FSCK_PASS'
        ;;
    alpine-verify)
        /sbin/e2fsck -f -n /dev/vda ||
            fail 'e2fsck rejected the checkpoint-restored Alpine/OpenRC ext4 root'
        echo 'VEYRA_SNAPCORE_ALPINE_E2FSCK_PASS'
        ;;
    mutate-root|delete-root|verify-root|alpine-baseline|alpine-mutate|alpine-delete|alpine-verify) ;;
    *)
        fail "unknown booted-root QEMU phase: $phase"
        ;;
esac

"$BB" mount -t ext4 -o noatime /dev/vda /mnt/snapcore ||
    fail 'could not mount the SnapCore-backed ext4 root'
"$BB" mkdir -p /mnt/snapcore/proc /mnt/snapcore/sys /mnt/snapcore/dev \
    /mnt/snapcore/run /mnt/snapcore/tmp
"$BB" mount -t proc proc /mnt/snapcore/proc ||
    fail 'could not mount proc in the restored root'
"$BB" mount -t sysfs sysfs /mnt/snapcore/sys ||
    fail 'could not mount sysfs in the restored root'
"$BB" mount -o move /dev /mnt/snapcore/dev ||
    fail 'could not move devtmpfs into the restored root'
"$BB" mount -t tmpfs -o mode=0755 tmpfs /mnt/snapcore/run ||
    fail 'could not mount run in the restored root'
"$BB" mount -t tmpfs -o mode=1777 tmpfs /mnt/snapcore/tmp ||
    fail 'could not mount tmp in the restored root'
exec "$BB" switch_root /mnt/snapcore /sbin/init
