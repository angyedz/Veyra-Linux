#!/bin/sh
# Veyra Recovery Environment: independent, non-destructive rescue init.
# Intended as /init in a dedicated recovery initramfs. Prototype: serial UI.
# No automatic disk writes, update execution, or filesystem formatting.
set -eu
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
# mkinitfs embeds BusyBox, but its applet symlinks are set up by Alpine's
# stock /init. A custom PID 1 must call those applets explicitly.
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev || true
/bin/busybox mkdir -p /dev/pts /run /tmp
/bin/busybox mount -t devpts devpts /dev/pts || true
/bin/busybox mount -t tmpfs tmpfs /run || true
/bin/busybox mount -t tmpfs tmpfs /tmp || true
/bin/busybox mkdir -p /run/veyra
/bin/busybox printf 'VEYRA-RECOVERY-v1\n' > /run/veyra/recovery-environment
/bin/busybox chmod 0444 /run/veyra/recovery-environment
[ -e /dev/console ] || /bin/busybox mknod /dev/console c 5 1
exec </dev/console >/dev/console 2>&1
printf '\033[2J\033[H'
echo '======================================================'
echo '              VEYRA RECOVERY ENVIRONMENT'
echo '======================================================'
echo 'Read-only recovery prototype. No disk changes are made.'
echo 'The graphical UI will use branding/veyra-logo.svg.'
echo
while :; do
    echo '1) Show block devices'
    echo '2) Show kernel boot command line'
    echo '3) Verify recovery environment marker'
    echo '4) Reboot'
    echo '5) Power off'
    printf 'Choice: '
    IFS= read -r choice || choice=3
    case "$choice" in
        1) /bin/busybox cat /proc/partitions ;;
        2) /bin/busybox cat /proc/cmdline ;;
        3) /bin/busybox cat /run/veyra/recovery-environment ;;
        4) /bin/busybox sync; /bin/busybox reboot -f ;;
        5) /bin/busybox sync; /bin/busybox poweroff -f ;;
        *) echo 'Unknown choice' ;;
    esac
done
