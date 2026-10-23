#!/bin/sh
# Choose live desktop or text console before the display manager starts.
set -eu
[ -r /etc/veyra-release ] || exit 0
mode=''
# Read kernel arguments as words, not lines.
# shellcheck disable=SC2013
for arg in $(cat /proc/cmdline); do
    case "$arg" in veyra.mode=tty) mode='tty' ;; veyra.mode=kde) mode='kde' ;; esac
done
if [ -z "$mode" ] && [ -c /dev/tty1 ]; then
    printf '\033[2J\033[H' > /dev/tty1
    printf 'Veyra Linux Live\n\n  1) Veyra Live KDE\n  2) Veyra Live TTY\n\nSelect [1, default KDE in 12 seconds]: ' > /dev/tty1
    choice=''
    # BusyBox ash supports timed reads; not specified by POSIX sh.
    # shellcheck disable=SC3045
    read -r -t 12 choice < /dev/tty1 || :
    case "$choice" in 2) mode='tty' ;; *) mode='kde' ;; esac
fi
if [ "$mode" = tty ]; then
    rc-update del sddm default >/dev/null 2>&1 || :
    if [ -f /etc/inittab ]; then
        sed -i '/^tty1::respawn:/c\\tty1::respawn:/sbin/agetty --autologin veyra 38400 tty1 linux' /etc/inittab
        telinit q 2>/dev/null || :
    fi
    touch /run/veyra-live-tty
    printf '\nTTY selected. Run: veyra-install --tui\n' > /dev/tty1
else
    # SDDM must own tty1 in graphical mode; the default Alpine getty races it
    # for the same VT and prevents the live Wayland session from starting.
    if [ -f /etc/inittab ]; then
        sed -i '/^tty1::respawn:/d' /etc/inittab
        telinit q 2>/dev/null || :
    fi
    printf '\nStarting KDE Plasma...\n' > /dev/tty1
fi
