#!/bin/sh
# shellcheck disable=SC2015 # Deliberate fail-closed conjunctions
# Build a Veyra-compatible initramfs /init from Alpine's locally installed
# original; do NOT edit or replace the packaged /usr/share/mkinitfs/initramfs-init.
# Called with an absolute output path. Use mkinitfs -i OUTPUT KERNEL_VERSION.
set -eu
[ "$#" -eq 1 ] || { echo 'usage: build-veyra-init.sh OUTPUT' >&2; exit 2; }
output=$1
case "$output" in /*) :;; *) echo 'Output path must be absolute' >&2; exit 2;; esac
scriptdir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
source=${VEYRA_MKINITFS_INIT:-/usr/share/mkinitfs/initramfs-init}
[ -f "$source" ] && [ ! -L "$source" ] ||
    { echo "Alpine initramfs source missing: $source" >&2; exit 1; }
[ ! -e "$output" ] && [ ! -L "$output" ] ||
    { echo "Refusing to overwrite initramfs script: $output" >&2; exit 1; }
inject="$scriptdir/veyra-initramfs-select.sh"
[ -f "$inject" ] || { echo 'Missing Veyra initramfs selector' >&2; exit 1; }
tmp="$output.tmp.$$"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
mkdir -p "$(dirname "$output")"
# Fail closed on Alpine changes to parsing/mount sequence. Alpine's own
# initramfs source must match these unique anchors before patching.
awk -v snippet="$inject" '
  $0 == "\trootfstype" {
      print
      print "\tveyra_deployment"
      opt++
      next
  }
  index($0, "if [ -r \"$sysroot/etc/fstab\" ] && [ \"$KOPT_usrflags\" != \"disable\" ]; then") {
      while ((getline line < snippet) > 0) print line
      close(snippet)
      anchor++
  }
  index($0, "if [ \"$DIR\" != \"/\" ") && index($0, "\"$sysroot/usr\"") {
      print "\t\tcase \"$DIR\" in \"$sysroot\"/*) continue ;; esac"
      mount_guard++
  }
  {print}
  END {
      if (opt != 1 || anchor != 1 || mount_guard != 1) {
          print "Unsupported Alpine mkinitfs init structure" > "/dev/stderr"
          exit 1
      }
  }
' "$source" > "$tmp"
sh -n "$tmp"
chmod 0755 "$tmp"
mv "$tmp" "$output"
echo "Generated Veyra deployment-aware initramfs /init: $output"
