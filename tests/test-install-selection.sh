#!/bin/sh
# Test installer package / service routing without writing to a real disk.
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
target="$tmp/target"
mkdir -p "$tmp/bin" "$target/etc/apk" "$target/lib/modules/6.12.0-test" "$tmp/pci/0000:01:00.0"
printf '%s\n' alpine-base > "$target/etc/apk/world"

cat > "$tmp/bin/mountpoint" <<'STUB'
#!/bin/sh
[ "$1" = -q ] && exit 0
exit 2
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
export VEYRA_CPUINFO="$tmp/cpuinfo"
export VEYRA_PCI_ROOT="$tmp/pci"
: > "$VEYRA_TEST_LOG"
sh "$root/scripts/installer-hardware.sh" "$target"
grep -q 'intel-ucode' "$VEYRA_TEST_LOG"
grep -q 'mesa-vulkan-nouveau' "$VEYRA_TEST_LOG"
grep -q 'linux-firmware-nvidia' "$VEYRA_TEST_LOG"
grep -q 'mkinitfs 6.12.0-test' "$VEYRA_TEST_LOG"
grep -q 'GenuineIntel' "$target/var/log/veyra/hardware-detected.txt"

echo 'Safe mocked installer routes passed'
