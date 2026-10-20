#!/bin/sh
# Disposable diskless, networkless initramfs namespace smoke test.
# Never installed to disk or used as the Veyra normal boot path.
set -eu
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mkdir -p /dev/pts /run /tmp /root
/bin/busybox mount -t devpts devpts /dev/pts
/bin/busybox mount -t tmpfs tmpfs /run
/bin/busybox mount -t tmpfs tmpfs /tmp
exec </dev/console >/dev/console 2>&1
/bin/busybox chmod 0700 /root
printf 'protected guest system marker\n' > /root/veyra-host-secret
/bin/busybox chmod 0600 /root/veyra-host-secret
if [ -e /proc/sys/kernel/unprivileged_userns_clone ]; then
    printf '1\n' > /proc/sys/kernel/unprivileged_userns_clone
fi
if [ -w /proc/sys/user/max_user_namespaces ]; then
    printf '1024\n' > /proc/sys/user/max_user_namespaces
fi
if /ns-check; then
    echo 'VEYRA_USERNS_QEMU_SUCCESS: rootless kernel namespace prerequisites'
else
    echo 'VEYRA_USERNS_QEMU_FAILURE: guest test failed'
fi
/bin/busybox sync
/bin/busybox poweroff -f
