#!/bin/sh
# Build ext4-capable Alpine initramfs images for disposable SnapCore QEMU tests.
set -eu
out=${1:-/out}
apk add --no-cache linux-lts mkinitfs e2fsprogs cpio gzip
kernel=$(basename "$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -print -quit)")
test -n "$kernel"

mkinitfs -F "base ext4 virtio" \
    -i /work/tests/fixtures/snapcore-ext4-qemu-init.sh \
    -o "$out/snapcore-ext4-initramfs" "$kernel"
mkinitfs -F "base ext4 virtio" \
    -i /work/tests/fixtures/snapcore-booted-root-qemu-init.sh \
    -o "$out/snapcore-booted-root-initramfs" "$kernel"

mkdir -p "$out/overlay/sbin" "$out/overlay/etc"
: > "$out/ext4-ldd-output"
for tool in mkfs.ext4 e2fsck; do
    binary=$(command -v "$tool")
    cp -L "$binary" "$out/overlay/sbin/$tool"
    ldd "$binary" >> "$out/ext4-ldd-output"
done
cp /etc/mke2fs.conf "$out/overlay/etc/mke2fs.conf"

awk '
    index($0, "=> /") { print $3; next }
    {
        path = $1
        sub(/:$/, "", path)
        if (substr(path, 1, 1) == "/" && index(path, ".so") > 0)
            print path
    }
' "$out/ext4-ldd-output" | sort -u > "$out/ext4-libraries"

while IFS= read -r library; do
    [ -f "$library" ] || continue
    mkdir -p "$out/overlay$(dirname "$library")"
    cp -L "$library" "$out/overlay$library"
done < "$out/ext4-libraries"

for image in "$out/snapcore-ext4-initramfs" "$out/snapcore-booted-root-initramfs"; do
    (
        cd "$out/overlay"
        find . -print | cpio --quiet -o -H newc | gzip -9
    ) >> "$image"
done
cp /boot/vmlinuz-lts "$out/snapcore-ext4-kernel"
chmod 0644 "$out/snapcore-ext4-kernel" \
    "$out/snapcore-ext4-initramfs" "$out/snapcore-booted-root-initramfs"
test -s "$out/snapcore-ext4-kernel"
test -s "$out/snapcore-ext4-initramfs"
test -s "$out/snapcore-booted-root-initramfs"
