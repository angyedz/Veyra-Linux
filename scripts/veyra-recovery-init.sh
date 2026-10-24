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
# Custom PID 1 replaces Alpine's init, so create BusyBox applet aliases
# for an independent root shell that does not rely on installed binaries.
if ! /bin/busybox --install -s /bin; then
    echo 'Warning: BusyBox command aliases could not be created.' >&2
fi
[ -e /dev/console ] || /bin/busybox mknod /dev/console c 5 1
exec </dev/console >/dev/console 2>&1
recovery_shell() {
    echo
    echo 'EXPERT MODE: independent Recovery root shell.'
    echo 'Commands can modify disks and bypass the normal menu.'
    echo 'No installed disk is mounted automatically.'
    echo 'Use exit to return to the Recovery menu.'
    printf 'Type SHELL to enter, or anything else to cancel: '
    IFS= read -r confirmation || confirmation=
    if [ "$confirmation" != SHELL ]; then
        echo 'Recovery shell cancelled.'
        return 0
    fi
    # Shell is a child of PID 1; exit must return to the menu, not kill init.
    /bin/busybox sh -i </dev/console >/dev/console 2>&1 || :
    echo 'Returned to Veyra Recovery.'
}

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
    echo '5) Recovery shell (expert mode)'
    printf 'Choice: '
    IFS= read -r choice || choice=3
    case "$choice" in
        1) /bin/busybox cat /proc/partitions ;;
        2) /bin/busybox cat /proc/cmdline ;;
        3) /bin/busybox sync; /bin/busybox reboot -f ;;
        4) /bin/busybox sync; /bin/busybox poweroff -f ;;
        5) recovery_shell ;;
        *) echo 'Unknown choice' ;;
    esac
done
