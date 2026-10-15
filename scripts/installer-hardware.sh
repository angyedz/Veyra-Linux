#!/bin/sh
# Use LIVE CPU/PCI information to install native firmware and graphics packages
# on the target. Never uses third-party driver installers or edge repositories.
set -eu
target="${1:?missing target path}"
case "$target" in /|''|/tmp|/mnt|/run) echo "Invalid target" >&2; exit 1 ;; esac
[ -f "$target/etc/apk/world" ] || { echo 'Missing target Alpine install' >&2; exit 1; }
mountpoint -q "$target" || { echo 'Target is not mounted' >&2; exit 1; }

detector=/usr/local/lib/veyra/hardware-detect.sh
[ -r "$detector" ] || {
    detector=$(CDPATH='' cd "$(dirname "$0")" && pwd)/hardware-detect.sh
}

echo 'Detecting CPU and graphics hardware:'
sh "$detector" --report
packages=$(sh "$detector" --packages)
[ -n "$packages" ] || {
    echo 'No vendor-specific firmware is necessary for detected hardware.'
    exit 0
}

# Hardware selection is an internal, audited list of package names.
# shellcheck disable=SC2086
set -- $packages
echo "Installing detected hardware support: $*"
# Failure is fatal: do not silently pretend the right drivers are installed.
chroot "$target" apk add --no-cache "$@" || {
    echo 'Hardware support installation failed. Check network and repositories.' >&2
    exit 1
}
mkdir -p "$target/var/log/veyra"
sh "$detector" --report > "$target/var/log/veyra/hardware-detected.txt"
printf '%s\n' "$packages" > "$target/var/log/veyra/hardware-packages.txt"
echo 'Hardware support installed.'
