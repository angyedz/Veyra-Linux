#!/bin/sh
# Test installer package / service routing without writing to a real disk.
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
sh -n "$root/scripts/veyra-sddm-runtime.initd"
target="$tmp/target"
mkdir -p "$tmp/bin" "$target/etc/apk" "$target/etc/init.d" \
    "$target/lib/modules/6.12.0-test" "$tmp/pci/0000:01:00.0"
printf '%s\n' alpine-base > "$target/etc/apk/world"

cat > "$tmp/bin/mountpoint" <<'STUB'
#!/bin/sh
[ "$1" = -q ] && exit 0
exit 2
STUB
cat > "$tmp/bin/findmnt" <<'STUB'
#!/bin/sh
printf '%s\n' "${VEYRA_TEST_FS:-ext4}"
STUB
cat > "$tmp/bin/chroot" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$VEYRA_TEST_LOG"
STUB
chmod 755 "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export VEYRA_TEST_LOG="$tmp/operations"

: > "$VEYRA_TEST_LOG"
sh "$root/scripts/installer-desktop.sh" "$target" plasma
grep -qx plasma "$target/etc/veyra/desktop"
grep -q 'rc-update add sddm default' "$VEYRA_TEST_LOG"
grep -q 'rc-update add openrc-settingsd default' "$VEYRA_TEST_LOG"
grep -q 'rc-update add veyra-sddm-runtime default' "$VEYRA_TEST_LOG"
cmp "$root/scripts/veyra-sddm-runtime.initd" "$target/etc/init.d/veyra-sddm-runtime"
if grep -Eq 'apk (add|del).* (gnome|xfce|lxqt)' "$VEYRA_TEST_LOG"; then
    echo 'KDE-only install must not mutate other desktop packages' >&2
    exit 1
fi

for desktop in gnome xfce lxqt anything-else ''; do
    if sh "$root/scripts/installer-desktop.sh" "$target" "$desktop" > /dev/null 2>&1; then
        echo "Unsupported desktop choice must be rejected: $desktop" >&2
        exit 1
    fi
done

printf '%s\n' 'vendor_id : GenuineIntel' > "$tmp/cpuinfo"
printf '%s\n' 0x030000 > "$tmp/pci/0000:01:00.0/class"
printf '%s\n' 0x10de > "$tmp/pci/0000:01:00.0/vendor"
export VEYRA_CPUINFO="$tmp/cpuinfo"
export VEYRA_PCI_ROOT="$tmp/pci"
: > "$VEYRA_TEST_LOG"
sh "$root/scripts/installer-hardware.sh" "$target"
grep -q 'intel-ucode' "$VEYRA_TEST_LOG"
grep -q 'mesa-vulkan-nouveau' "$VEYRA_TEST_LOG"
grep -q 'linux-firmware-nvidia' "$VEYRA_TEST_LOG"
grep -q 'mkinitfs 6.12.0-test' "$VEYRA_TEST_LOG"
grep -q 'GenuineIntel' "$target/var/log/veyra/hardware-detected.txt"
grep -q 'rootfstype=ext4' "$target/etc/default/grub"
grep -q 'ext4 virtio nvme' "$target/etc/mkinitfs/mkinitfs.conf"

# Unsupported filesystems must not generate an unbootable initramfs.
if VEYRA_TEST_FS=tmpfs sh "$root/scripts/installer-hardware.sh" "$target" >/dev/null 2>&1; then
    echo 'Unsupported root filesystem must be rejected' >&2
    exit 1
fi

echo 'Safe mocked installer routes passed'
