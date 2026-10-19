#!/bin/sh
# Veyra Recovery Environment: independent, non-destructive rescue init.
# Intended as /init in a dedicated recovery initramfs. Prototype: serial UI.
# No automatic disk writes, update execution, or filesystem formatting.
set -eu
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev || true
mkdir -p /dev/pts /run /tmp
mount -t devpts devpts /dev/pts || true
mount -t tmpfs tmpfs /run || true
mount -t tmpfs tmpfs /tmp || true
[ -e /dev/console ] || mknod /dev/console c 5 1
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
    echo '3) Reboot'
    echo '4) Power off'
    printf 'Choice: '
    IFS= read -r choice || choice=3
    case "$choice" in
        1) cat /proc/partitions ;;
        2) cat /proc/cmdline ;;
        3) sync; reboot -f ;;
        4) sync; poweroff -f ;;
        *) echo 'Unknown choice' ;;
    esac
done
