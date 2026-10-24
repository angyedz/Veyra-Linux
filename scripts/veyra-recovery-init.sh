#!/bin/sh
# Veyra Recovery Environment: independent, confirmation-gated rescue init.
# Intended as /init in a dedicated recovery initramfs; serial UI for now.
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

update_available() {
    [ -x /usr/sbin/veyra-atomic-update ] &&
        [ -x /usr/libexec/veyra/bootctl ] &&
        [ -f /etc/veyra/update-manifest-url ] &&
        [ -f /etc/veyra/trust/update-ed25519.pub ]
}

apply_signed_update() {
    store=/mnt/veyra-store
    printf 'Offline Veyra store partition (for example /dev/vda1): '
    IFS= read -r device || return 1
    case "$device" in
        /dev/*) ;;
        *) echo 'Enter a direct block-device path under /dev.'; return 1 ;;
    esac
    case "$device" in
        /dev/*/*|*..*|*[!A-Za-z0-9/_-]*)
            echo 'That device path is not supported.'; return 1 ;;
    esac
    [ -b "$device" ] || { echo 'The selected path is not a block device.'; return 1; }
    /bin/busybox mkdir -p "$store"
    /bin/busybox mount -o ro "$device" "$store" || {
        echo 'Could not mount the selected partition read-only.'
        return 1
    }
    if [ -L "$store/.veyra-deployment-store" ] ||
        [ "$(/bin/busybox cat "$store/.veyra-deployment-store" 2>/dev/null)" != \
            VEYRA-DEPLOYMENT-STORE-v2 ]; then
        echo 'This partition is not a Veyra deployment store.'
        /bin/busybox umount "$store"
        return 1
    fi
    if ! /usr/libexec/veyra/bootctl --store "$store" status; then
        echo 'The store boot state could not be verified.'
        /bin/busybox umount "$store"
        return 1
    fi
    echo 'Only inactive system and user generations will be staged.'
    echo 'The last confirmed pair stays selected until the trial is armed.'
    printf 'Type UPDATE to authorize writes to this store: '
    IFS= read -r confirmation || confirmation=
    if [ "$confirmation" != UPDATE ]; then
        echo 'Update cancelled.'
        /bin/busybox umount "$store"
        return 0
    fi
    /bin/busybox umount "$store" || {
        echo 'Could not release the read-only inspection mount.'
        return 1
    }
    /bin/busybox mount -o rw "$device" "$store" || {
        echo 'Could not remount the Veyra store for the authorized update.'
        return 1
    }

    dhcp_script=/tmp/veyra-udhcpc.sh
    cat > "$dhcp_script" <<'DHCP'
#!/bin/sh
case "$1" in
    deconfig)
        /bin/busybox ifconfig "$interface" 0.0.0.0
        ;;
    bound|renew)
        /bin/busybox ifconfig "$interface" "$ip" netmask "$subnet" up
        /bin/busybox route del default 2>/dev/null || :
        for gateway in $router; do
            /bin/busybox route add default gw "$gateway" "$interface" && break
        done
        : > /etc/resolv.conf
        for nameserver in $dns; do
            printf 'nameserver %s\n' "$nameserver" >> /etc/resolv.conf
        done
        ;;
esac
exit 0
DHCP
    /bin/busybox chmod 0700 "$dhcp_script"
    network_ready=0
    for interface_path in /sys/class/net/*; do
        interface=${interface_path##*/}
        [ "$interface" = lo ] && continue
        if /bin/busybox udhcpc -i "$interface" -n -q -t 5 -T 3 \
            -s "$dhcp_script"; then
            network_ready=1
            break
        fi
    done
    if [ "$network_ready" -ne 1 ]; then
        echo 'No network connection was obtained; no update was staged.'
        /bin/busybox umount "$store"
        return 1
    fi

    if /usr/sbin/veyra-atomic-update --offline --store "$store"; then
        /bin/busybox sync
        if ! /bin/busybox umount "$store"; then
            echo 'Update staged, but the store could not be cleanly unmounted; do not reboot yet.'
            return 1
        fi
        echo 'Signed update staged. Reboot to try the new paired generation.'
        return 0
    else
        update_status=$?
    fi
    /bin/busybox sync
    echo "Update failed with status $update_status; the confirmed pair remains active."
    if ! /bin/busybox umount "$store"; then
        echo 'The store could not be cleanly unmounted.'
    fi
    return 1
}

# This is an explicit expert-only shell, not a repair wizard. It runs in the
# independent initramfs (never a chroot into the installed system).
# No installed root or deployment store is mounted by this menu action.
recovery_shell() {
    echo
    echo 'EXPERT MODE: root shell in the independent Recovery initramfs.'
    echo 'Commands can overwrite disks and bypass menu confirmations.'
    echo 'No installed filesystem is mounted automatically.'
    echo 'Use exit to return to the Recovery menu.'
    printf 'Type SHELL to continue, or anything else to cancel: '
    IFS= read -r confirmation || confirmation=
    if [ "$confirmation" != SHELL ]; then
        echo 'Recovery shell cancelled.'
        return 0
    fi
    # Do not exec here: PID 1 must keep running to recover the menu.
    # BusyBox supplies the shell without relying on the installed root.
    /bin/busybox sh -i </dev/console >/dev/console 2>&1 || :
    echo 'Returned to Veyra Recovery.'
}

printf '\033[2J\033[H'
echo '======================================================'
echo '              VEYRA RECOVERY ENVIRONMENT'
echo '======================================================'
echo 'Offline rescue. Disk writes require an explicit confirmation.'
echo 'The graphical UI will use branding/veyra-logo.svg.'
echo
while :; do
    echo '1) Show block devices'
    echo '2) Show kernel boot command line'
    echo '3) Verify recovery environment marker'
    update_option=4
    if update_available; then
        echo '4) Apply a signed update to an offline Veyra store'
        update_option=5
    fi
    echo "$update_option) Reboot"
    echo "$((update_option + 1))) Power off"
    echo "$((update_option + 2))) Recovery shell (expert mode)"
    printf 'Choice: '
    IFS= read -r choice || choice=3
    case "$choice" in
        1) /bin/busybox cat /proc/partitions ;;
        2) /bin/busybox cat /proc/cmdline ;;
        3) /bin/busybox cat /run/veyra/recovery-environment ;;
        4)
            if update_available; then
                apply_signed_update || echo 'Recovery update did not complete.'
            else
                /bin/busybox sync; /bin/busybox reboot -f
            fi
            ;;
        "$update_option") /bin/busybox sync; /bin/busybox reboot -f ;;
        "$((update_option + 1))") /bin/busybox sync; /bin/busybox poweroff -f ;;
        "$((update_option + 2))") recovery_shell ;;
        *) echo 'Unknown choice' ;;
    esac
done
