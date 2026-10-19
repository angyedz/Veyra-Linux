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
[ ! -e "$output" ] && [ ! -L "$output" ] ||
    { echo 'refusing to overwrite existing recovery artifact' >&2; exit 1; }
command -v mkinitfs >/dev/null 2>&1 || { echo 'mkinitfs required' >&2; exit 1; }
scriptdir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
init="$scriptdir/veyra-recovery-init.sh"
[ -f "$init" ] && [ ! -L "$init" ] || { echo 'missing recovery init' >&2; exit 1; }
sh -n "$init"
[ -d "/lib/modules/$kernel" ] || { echo 'kernel modules not installed' >&2; exit 1; }
mkdir -p "$(dirname "$output")"
tmp="$output.tmp.$$"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
# Alpine mkinitfs includes BusyBox and the selected hardware features.
# Explicitly keep this out of the GRUB boot path until a real QEMU boot test.
mkinitfs -i "$init" -o "$tmp" "$kernel"
[ -s "$tmp" ] || { echo 'empty recovery image' >&2; exit 1; }
mv "$tmp" "$output"
echo "Built Veyra recovery image: $output"
echo 'NOT INSTALLED: boot entry and standalone QEMU verification still required'
