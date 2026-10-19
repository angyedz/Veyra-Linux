#!/bin/sh
# EXPERIMENTAL: rootless bootstrap of a prepared Alpine/OpenRC rootfs.
# NOT a proven isolation boundary or production system service.
set -eu
die() { printf 'veyra-user-env: %s\n' "$*" >&2; exit 1; }
usage() { die 'usage: veyra-user-env-prototype.sh [--check] /canonical/rootfs'; }
check_only=0
case "$#" in
    1) requested_root=$1 ;;
    2) [ "$1" = --check ] || usage; check_only=1; requested_root=$2 ;;
    *) usage ;;
esac
case "$requested_root" in /*) : ;; *) die 'rootfs must be absolute' ;; esac
[ "$requested_root" != / ] || die 'refusing host root'
[ "$(id -u)" -ne 0 ] || die 'must run as an ordinary host user'
if [ ! -d "$requested_root" ] || [ -L "$requested_root" ]; then
    die 'rootfs must be a real directory'
fi
root=$(CDPATH='' cd -P "$requested_root" && pwd -P) || die 'cannot resolve rootfs'
[ "$root" = "$requested_root" ] ||
    die 'rootfs must have a canonical physical path, no symlink ancestors'
[ "$(stat -c '%u' "$root")" = "$(id -u)" ] ||
    die 'the unprivileged caller must own the rootfs'
command -v findmnt >/dev/null 2>&1 || die 'missing findmnt'
# This limited prototype refuses rootfs mountpoints or child mounts:
# do not carry privileged host mounts into the user namespace.
if findmnt -rn -o TARGET -R "$root" 2>/dev/null | grep -q .; then
    die 'mounted rootfs or submount found; unsupported in this prototype'
fi
if [ -e "$root/.veyra-old-root" ] || [ -L "$root/.veyra-old-root" ]; then
    die 'stale or hostile pivot_root directory'
fi
for d in etc etc/init.d etc/runlevels sbin dev proc sys run tmp; do
    if [ ! -d "$root/$d" ] || [ -L "$root/$d" ]; then
        die "missing real rootfs directory: $d"
    fi
done
[ -x "$root/sbin/init" ] || die 'missing executable rootfs /sbin/init'
for tool in unshare mount pivot_root umount env; do
    command -v "$tool" >/dev/null 2>&1 || die "missing $tool"
done
if [ "$check_only" -eq 1 ]; then
    echo 'PASS: rootfs ownership/layout preflight only'
    echo 'NOTE: no init boot, UID mapping or security claim'
    exit 0
fi
# This maps only namespace UID 0 to an UNPRIVILEGED host UID.
# It CANNOT support a normal user+sudo; multi-ID mapping is future work.
# Clear inherited D-Bus, Wayland, linker and desktop environment variables.
# Inherited file descriptors still need auditing in the future supervisor.
# shellcheck disable=SC2016
exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/ TERM="${TERM:-dumb}" \
    unshare --user --map-root-user --mount --pid --ipc --net --uts \
    --propagation private --fork -- sh -eu -c '
        root=$1
        mount --make-rprivate /
        mount --bind "$root" "$root"
        mount --make-private "$root"
        cd "$root"
        mkdir .veyra-old-root
        pivot_root . .veyra-old-root
        cd /
        # Detaching the old mount does not prove inherited FDs are closed.
        umount -l /.veyra-old-root
        rmdir /.veyra-old-root
        mount -t proc proc /proc -o nosuid,nodev,noexec
        mount -t tmpfs tmpfs /run -o mode=0755,nosuid,nodev
        mount -t tmpfs tmpfs /tmp -o mode=1777,nosuid,nodev
        # Devices, network link, OpenRC boot and sudo are NOT implemented.
        exec /sbin/init
    ' sh "$root"
