#!/bin/sh
# Render an opt-in Veyra GRUB theme from the repository's REAL SVG logo.
# This prepares artifacts only. It never edits the running GRUB setup.
set -eu
die() { echo "veyra-boot-theme: $*" >&2; exit 1; }
[ "$#" -eq 1 ] || die 'usage: build-veyra-boot-theme.sh /new/output-directory'
output=$1
case "$output" in /*) : ;; *) die 'output directory must be absolute' ;; esac
[ "$output" != / ] || die 'refusing filesystem root'
if [ -e "$output" ] || [ -L "$output" ]; then
    die 'refusing to replace an existing directory'
fi
command -v rsvg-convert >/dev/null 2>&1 ||
    die 'requires rsvg-convert (Alpine 3.22 package: rsvg-convert)'
repo=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
logo="$repo/branding/veyra-logo.svg"
theme="$repo/branding/grub/theme.txt"
if [ ! -f "$logo" ] || [ -L "$logo" ]; then
    die 'canonical SVG logo missing'
fi
if [ ! -f "$theme" ] || [ -L "$theme" ]; then
    die 'GRUB theme source missing'
fi
mkdir -p "$(dirname "$output")"
mkdir -m 0755 "$output"
rsvg-convert --width 144 --height 144 --output "$output/veyra-logo.png" "$logo" ||
    die 'failed to render canonical logo'
[ -s "$output/veyra-logo.png" ] || die 'empty logo PNG'
cp "$theme" "$output/theme.txt"
chmod 0644 "$output/veyra-logo.png" "$output/theme.txt"
echo "Veyra GRUB theme generated: $output"
echo 'NOT INSTALLED: does not modify GRUB or boot selection'
