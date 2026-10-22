#!/bin/sh
# Test installer package / service routing without writing to a real disk.
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
target="$tmp/target"
mkdir -p "$tmp/bin" "$target/etc/apk" "$target/lib/modules/6.12.0-test" \
    "$tmp/pci/0000:00:02.0" "$tmp/pci/0000:01:00.0"
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

for desktop in plasma gnome xfce lxqt; do
    : > "$VEYRA_TEST_LOG"
    sh "$root/scripts/installer-desktop.sh" "$target" "$desktop"
    grep -qx "$desktop" "$target/etc/veyra/desktop"
    case "$desktop" in
        plasma|lxqt) manager=sddm ;;
        gnome) manager=gdm ;;
        xfce) manager=lightdm ;;
    esac
    grep -q "rc-update add $manager default" "$VEYRA_TEST_LOG"
    case "$desktop" in
        gnome) grep -q 'apk add --no-cache gnome gdm gdm-openrc' "$VEYRA_TEST_LOG" ;;
        xfce) grep -q 'lightdm-gtk-greeter' "$VEYRA_TEST_LOG" ;;
        lxqt) grep -q 'lxqt-desktop' "$VEYRA_TEST_LOG" ;;
    esac
done

if sh "$root/scripts/installer-desktop.sh" "$target" 'anything-else' > /dev/null 2>&1; then
    echo 'Unknown desktop choice must be rejected' >&2
    exit 1
fi

printf '%s\n' 'vendor_id : GenuineIntel' > "$tmp/cpuinfo"
printf '%s\n' 0x030000 > "$tmp/pci/0000:01:00.0/class"
printf '%s\n' 0x10de > "$tmp/pci/0000:01:00.0/vendor"
printf '%s\n' 0x030000 > "$tmp/pci/0000:00:02.0/class"
printf '%s\n' 0x8086 > "$tmp/pci/0000:00:02.0/vendor"
export VEYRA_CPUINFO="$tmp/cpuinfo"
export VEYRA_PCI_ROOT="$tmp/pci"
: > "$VEYRA_TEST_LOG"
sh "$root/scripts/installer-hardware.sh" "$target"
grep -q 'intel-ucode' "$VEYRA_TEST_LOG"
grep -q 'mesa-vulkan-intel' "$VEYRA_TEST_LOG"
grep -q 'linux-firmware-i915' "$VEYRA_TEST_LOG"
grep -q 'libva-intel-driver' "$VEYRA_TEST_LOG"
grep -q 'intel-media-driver' "$VEYRA_TEST_LOG"
grep -q 'mesa-vulkan-nouveau' "$VEYRA_TEST_LOG"
grep -q 'mesa-va-gallium' "$VEYRA_TEST_LOG"
grep -q 'linux-firmware-nvidia' "$VEYRA_TEST_LOG"
grep -q 'mkinitfs 6.12.0-test' "$VEYRA_TEST_LOG"
grep -q 'GenuineIntel' "$target/var/log/veyra/hardware-detected.txt"
grep -q 'rootfstype=ext4' "$target/etc/default/grub"
grep -q 'ext4 virtio nvme' "$target/etc/mkinitfs/mkinitfs.conf"

# AMD-only hardware selects the matching Mesa and firmware stack as well.
rm -rf "$tmp/pci"
mkdir -p "$tmp/pci/0000:03:00.0"
printf '%s\n' 'vendor_id : AuthenticAMD' > "$tmp/cpuinfo"
printf '%s\n' 0x030000 > "$tmp/pci/0000:03:00.0/class"
printf '%s\n' 0x1002 > "$tmp/pci/0000:03:00.0/vendor"
: > "$VEYRA_TEST_LOG"
sh "$root/scripts/installer-hardware.sh" "$target"
grep -q 'amd-ucode' "$VEYRA_TEST_LOG"
grep -q 'mesa-vulkan-ati' "$VEYRA_TEST_LOG"
grep -q 'mesa-va-gallium' "$VEYRA_TEST_LOG"
grep -q 'linux-firmware-amdgpu' "$VEYRA_TEST_LOG"
if grep -q 'mesa-vulkan-nouveau' "$VEYRA_TEST_LOG"; then
    echo 'AMD-only installation must not select Nouveau' >&2
    exit 1
fi

# Unsupported filesystems must not generate an unbootable initramfs.
if VEYRA_TEST_FS=tmpfs sh "$root/scripts/installer-hardware.sh" "$target" >/dev/null 2>&1; then
    echo 'Unsupported root filesystem must be rejected' >&2
    exit 1
fi

echo 'Safe mocked installer routes passed'
