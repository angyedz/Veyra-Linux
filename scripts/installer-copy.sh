#!/bin/sh
# Called only by Calamares after the user confirms partition changes.
set -eu
target="${1:?target root not given}"
case "$target" in
    /|''|/tmp|/mnt|/run) echo 'Refusing dangerous target' >&2; exit 1 ;;
esac
if [ ! -d "$target" ]; then
    echo "Calamares has not prepared a usable destination: $target" >&2
    exit 1
fi
mountpoint -q "$target" || {
    echo "Target root is not mounted: $target" >&2
    exit 1
}

rsync -aHAX --numeric-ids --one-file-system \
    --exclude='/dev/***' --exclude='/proc/***' --exclude='/sys/***' \
    --exclude='/run/***' --exclude='/tmp/***' \
    --exclude='/media/***' --exclude='/mnt/***' \
    --exclude='/home/veyra/***' --exclude='/var/cache/apk/***' \
    --exclude='/etc/sddm.conf.d/zz-veyra-live.conf' \
    --exclude='/etc/runlevels/boot/veyra-live' \
    / "$target/"
test -f "$target/etc/apk/world"
echo "Copied Veyra root filesystem to $target"
