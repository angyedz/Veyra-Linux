#!/bin/sh
# Build an experimental, standalone Veyra Recovery initramfs using Alpine
# mkinitfs. Does not modify GRUB or any installed root.
# Usage: build-veyra-recovery.sh KERNEL_VERSION OUTPUT_INITRAMFS
set -eu
[ "$#" -eq 2 ] || { echo 'usage: build-veyra-recovery.sh KERNEL_VERSION OUTPUT' >&2; exit 2; }
kernel=$1
output=$2
case "$kernel" in ''|*[!a-zA-Z0-9._-]*) echo 'invalid kernel version' >&2; exit 2;; esac
case "$output" in /*) :;; *) echo 'output must be absolute' >&2; exit 2;; esac
if [ -e "$output" ] || [ -L "$output" ]; then
    echo 'refusing to overwrite existing recovery artifact' >&2
    exit 1
fi
command -v mkinitfs >/dev/null 2>&1 || { echo 'mkinitfs required' >&2; exit 1; }
scriptdir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
init="$scriptdir/veyra-recovery-init.sh"
if [ ! -f "$init" ] || [ -L "$init" ]; then
    echo 'missing recovery init' >&2
    exit 1
fi
sh -n "$init"
[ -d "/lib/modules/$kernel" ] || { echo 'kernel modules not installed' >&2; exit 1; }
mkdir -p "$(dirname "$output")"
tmp="$output.tmp.$$"
features_dir=
cleanup() {
    rm -f "$tmp"
    if [ -n "$features_dir" ]; then
        rm -rf "$features_dir"
    fi
}
trap cleanup EXIT HUP INT TERM
# Alpine mkinitfs includes BusyBox and the selected hardware features.
# If the installed root has a complete signed-update configuration, carry the
# minimal updater runtime into the independent Recovery initramfs as well.
if [ -x /usr/sbin/veyra-atomic-update ]; then
    for required in \
        /usr/libexec/veyra/bootctl \
        /usr/libexec/veyra/veyra-deployment.sh \
        /etc/veyra/update-manifest-url \
        /etc/veyra/trust/update-ed25519.pub; do
        [ -f "$required" ] && [ ! -L "$required" ] || {
            echo "Recovery updater configuration is incomplete: $required" >&2
            exit 1
        }
    done
    for utility in apk rsync unshare python3 grub-editenv findmnt blkid; do
        command -v "$utility" >/dev/null 2>&1 || {
            echo "Recovery updater requires $utility" >&2
            exit 1
        }
    done
    mkinitfs_config=${VEYRA_MKINITFS_CONFIG:-/etc/mkinitfs/mkinitfs.conf}
    [ -f "$mkinitfs_config" ] || {
        echo "mkinitfs configuration is missing: $mkinitfs_config" >&2
        exit 1
    }
    features_dir=$(mktemp -d)
    feature_files="$features_dir/veyra-update.files"
    cat > "$feature_files" <<'FILES'
/usr/sbin/veyra-atomic-update
/usr/libexec/veyra/bootctl
/usr/libexec/veyra/veyra-deployment.sh
/etc/veyra/update-manifest-url
/etc/veyra/trust/update-ed25519.pub
/etc/ssl/cert.pem
/etc/ssl/certs
FILES
    for utility in apk rsync unshare python3 grub-editenv findmnt blkid; do
        utility_path=$(command -v "$utility")
        printf '%s\n' "${utility_path#/}" >> "$feature_files"
    done
    python_stdlib=$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')
    [ -d "$python_stdlib" ] || {
        echo 'Python standard library is missing' >&2
        exit 1
    }
    printf '%s\n' "${python_stdlib#/}" >> "$feature_files"
    # mkinitfs.conf is a shell assignment file used by mkinitfs itself.
    # shellcheck disable=SC1090,SC1091
    . "$mkinitfs_config"
    recovery_features="${features:-base} veyra-update"
    mkinitfs -P "$features_dir" -F "$recovery_features" \
        -i "$init" -o "$tmp" "$kernel"
else
    # The diskless QEMU recovery remains useful without updater configuration.
    mkinitfs -i "$init" -o "$tmp" "$kernel"
fi
[ -s "$tmp" ] || { echo 'empty recovery image' >&2; exit 1; }
# Alpine mkinitfs produces root-only images by default; the resulting
# non-secret recovery artifact must also be readable by the QEMU runner.
chmod 0644 "$tmp"
mv "$tmp" "$output"
echo "Built Veyra recovery image: $output"
if [ -x /usr/sbin/veyra-atomic-update ]; then
    echo 'Built with signed-update runtime; boot entry and end-to-end update remain unverified.'
else
    echo 'Built without update support: the updater package and signed channel are not configured.'
fi
echo 'NOT INSTALLED: boot entry and standalone QEMU verification still required'
