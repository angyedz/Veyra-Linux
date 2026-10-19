#!/bin/sh
# EXPERIMENTAL: rootless, isolated boot of a pre-populated Alpine/OpenRC rootfs.
# No network, host devices, host D-Bus, host graphics or privileged bridge.
# Never install as the default login path without an adversarial audit.
set -eu

die() { echo "veyra-user-env: $*" >&2; exit 1; }
usage() { die 'usage: veyra-user-env-prototype.sh /absolute/prepared-rootfs'; }

[ "$#" -eq 1 ] || usage
root=$1
case "$root" in /*) ;; *) usage ;; esac
[ "$root" != / ] || die 'refusing host root'
[ "$(id -u)" -ne 0 ] || die 'must run as an unprivileged host account'
[ -d "$root" ] && [ ! -L "$root" ] || die 'rootfs must be a real directory'
[ -x "$root/sbin/init" ] || die 'rootfs needs its own executable /sbin/init'
for d in etc proc sys dev run tmp; do
    [ -d "$root/$d" ] && [ ! -L "$root/$d" ] ||
        die "rootfs must provide a real $d directory"
done
for tool in unshare mount pivot_root umount chroot; do
    command -v "$tool" >/dev/null 2>&1 || die "missing $tool"
done

# Do not inherit elevated credentials or caller-supplied file descriptors
# from a privileged parent. The caller is deliberately an ordinary user.
# No bind mounts of the host's /dev, /sys, /run or system store are permitted.
exec unshare --user --map-root-user --mount --pid --ipc --net --uts \
    --fork -- sh -eu -c '
        root=$1
        mount --make-rprivate /
        mount --bind "$root" "$root"
        mount --make-private "$root"
        cd "$root"
        mkdir -p .veyra-old-root
        pivot_root . .veyra-old-root
        cd /
        umount -l /.veyra-old-root
        rmdir /.veyra-old-root
        # PID 1 of the child namespace is the user environment init.
        # Mount a new procfs; never reuse the host procfs.
        mount -t proc proc /proc -o nosuid,nodev,noexec
        mount -t tmpfs tmpfs /run -o mode=0755,nosuid,nodev
        mount -t tmpfs tmpfs /tmp -o mode=1777,nosuid,nodev
        # Deliberately no network veth or /dev access in this prototype.
        exec /sbin/init
    ' sh "$root"
