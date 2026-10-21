#!/bin/sh
# Build ext4-capable Alpine initramfs images for disposable SnapCore QEMU tests.
set -eu
out=${1:-/out}
apk add --no-cache linux-lts mkinitfs e2fsprogs cpio gzip build-base \
    git autoconf automake libtool pkgconf g++ liburing-dev linux-headers util-linux
apk add --no-cache alpine-base openrc
kernel=$(basename "$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -print -quit)")
test -n "$kernel"
ublk_module=$(find "/lib/modules/$kernel" -type f -name 'ublk_drv.ko*' -print -quit)
test -n "$ublk_module"
mkdir -p /etc/mkinitfs/features.d
ublk_module_rel=${ublk_module#"/lib/modules/$kernel/"}
printf '%s\n' "$ublk_module_rel" > /etc/mkinitfs/features.d/snapcore_ublk.modules

# Build the pinned upstream ublk server used only in the disposable QEMU guest.
ublksrv_ref=6d0d922614ec18e6f2b5d476af8d540a1d9c1de8
ublksrv_src=/tmp/ublksrv
rm -rf "$ublksrv_src"
git clone https://github.com/ublk-org/ublksrv.git "$ublksrv_src"
git -C "$ublksrv_src" checkout --detach "$ublksrv_ref"

# Alpine's fortified musl strdupa macro expands through a void* expression
# inside strcpy; C++ rejects it even with a call-site cast. Replace the two
# scratch copies with owned heap buffers in this pinned upstream source.
ublksrv_target="$ublksrv_src/targets/ublksrv_tgt.cpp"
test "$(grep -F -c '__mkpath(dirname(strdupa(dir)), 0755);' "$ublksrv_target")" -eq 1
test "$(grep -F -c 'ret = __mkpath(strdupa(dir), mode);' "$ublksrv_target")" -eq 1
awk '
    index($0, "__mkpath(dirname(strdupa(dir)), 0755);") {
        print "\tchar *parent = strdup(dir);"
        print "\tif (!parent) return -ENOMEM;"
        print "\t__mkpath(dirname(parent), 0755);"
        print "\tfree(parent);"
        next
    }
    index($0, "ret = __mkpath(strdupa(dir), mode);") {
        print "\tchar *dir_copy = strdup(dir);"
        print "\tif (!dir_copy) return -ENOMEM;"
        print "\tret = __mkpath(dir_copy, mode);"
        print "\tfree(dir_copy);"
        next
    }
    { print }
' "$ublksrv_target" > "$ublksrv_target.veyra"
mv "$ublksrv_target.veyra" "$ublksrv_target"
test "$(grep -F -c 'strdupa(dir)' "$ublksrv_target")" -eq 0

# Alpine musl already declares prctl_mm_map and PR_SET_IO_FLUSHER in
# sys/prctl.h. Upstream's extra Linux UAPI include redeclares the struct.
grep -qx '#include <linux/prctl.h>' "$ublksrv_src/lib/ublksrv.c"
sed -i 's@^#include <linux/prctl.h>$@@' "$ublksrv_src/lib/ublksrv.c"
(
    cd "$ublksrv_src"
    autoreconf -i
    ./configure --prefix=/usr --with-libnfs=no --with-libiscsi=no --with-gnutls=no
    # Build only the loop front end and CLI required by this QEMU fixture;
    # upstream demos include glibc-only <error.h> and are not runtime inputs.
    # Explicit root targets do not build the library subdirectory first.
    make -C lib -j2 libublksrv.la
    make -j2 ublk ublk.loop
    make -C lib install
    mkdir -p /usr/sbin
    cp ublk /usr/sbin/ublk
    cp ublk.loop /usr/sbin/ublk.loop
    chmod 0755 /usr/sbin/ublk /usr/sbin/ublk.loop
)
test -x /usr/sbin/ublk
test -x /usr/sbin/ublk.loop

# Build a disposable Alpine/OpenRC root used only by the SnapCore QEMU test.
alpine_root=$out/alpine-openrc-root
mkdir -p "$alpine_root"
apk --root "$alpine_root" --initdb \
    --keys-dir /etc/apk/keys \
    --repositories-file /etc/apk/repositories \
    add alpine-base openrc
test -x "$alpine_root/sbin/init"
test -x "$alpine_root/sbin/openrc"
rm -rf "$alpine_root/etc/runlevels"
mkdir -p "$alpine_root/etc/runlevels/sysinit" \
    "$alpine_root/etc/runlevels/boot" \
    "$alpine_root/etc/runlevels/default" \
    "$alpine_root/etc/init.d" "$alpine_root/usr/lib" \
    "$alpine_root/root" "$alpine_root/dev" "$alpine_root/proc" \
    "$alpine_root/sys" "$alpine_root/run" "$alpine_root/tmp"
cp /work/tests/fixtures/snapcore-alpine-openrc-inittab \
    "$alpine_root/etc/inittab"
cp /work/tests/fixtures/snapcore-alpine-openrc.initd \
    "$alpine_root/etc/init.d/veyra-snapcore-openrc"
chmod 0755 "$alpine_root/etc/init.d/veyra-snapcore-openrc"
ln -s /etc/init.d/veyra-snapcore-openrc \
    "$alpine_root/etc/runlevels/default/veyra-snapcore-openrc"
printf '%s\n' 'baseline-alpine-openrc-root' \
    > "$alpine_root/usr/lib/veyra-snapcore-root-marker"
printf '%s\n' 'DISPOSABLE_QEMU_ROOT_V1' \
    > "$alpine_root/etc/veyra-snapcore-root-fixture"

mkinitfs -F "base ext4 virtio snapcore_ublk" \
    -i /work/tests/fixtures/snapcore-ext4-qemu-init.sh \
    -o "$out/snapcore-ext4-initramfs" "$kernel"
mkinitfs -F "base ext4 virtio snapcore_ublk" \
    -i /work/tests/fixtures/snapcore-booted-root-qemu-init.sh \
    -o "$out/snapcore-booted-root-initramfs" "$kernel"

mkdir -p "$out/overlay/sbin" "$out/overlay/etc" \
    "$out/overlay/usr/sbin" "$out/overlay/usr/bin"
cc -static -Os -Wall -Wextra -Werror \
    -o "$out/overlay/sbin/veyra-wipe-root" \
    /work/tests/fixtures/snapcore-wipe-root.c
chmod 0755 "$out/overlay/sbin/veyra-wipe-root"
cp "$out/overlay/sbin/veyra-wipe-root" \
    "$alpine_root/sbin/veyra-wipe-root"
: > "$out/ext4-ldd-output"
for tool in mkfs.ext4 e2fsck; do
    binary=$(command -v "$tool")
    cp -L "$binary" "$out/overlay/sbin/$tool"
    ldd "$binary" >> "$out/ext4-ldd-output"
done
cp /etc/mke2fs.conf "$out/overlay/etc/mke2fs.conf"

cp /work/tests/fixtures/snapcore-ublk-start-inner.sh \
    "$out/overlay/sbin/veyra-snapcore-ublk-start-inner"
chmod 0755 "$out/overlay/sbin/veyra-snapcore-ublk-start-inner"
: > "$out/ublk-ldd-output"
for binary in /usr/sbin/ublk /usr/sbin/ublk.loop "$(command -v unshare)"; do
    test -x "$binary"
    if [ "$binary" = "$(command -v unshare)" ]; then
        cp -L "$binary" "$out/overlay/usr/bin/unshare"
    else
        cp -L "$binary" "$out/overlay$binary"
    fi
    ldd "$binary" >> "$out/ublk-ldd-output"
done

cat "$out/ext4-ldd-output" "$out/ublk-ldd-output" > "$out/initramfs-ldd-output"
awk '
    index($0, "=> /") { print $3; next }
    {
        path = $1
        sub(/:$/, "", path)
        if (substr(path, 1, 1) == "/" && index(path, ".so") > 0)
            print path
    }
' "$out/initramfs-ldd-output" | sort -u > "$out/ext4-libraries"

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
