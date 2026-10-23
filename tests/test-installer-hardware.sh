#!/bin/sh
# Exercise the complete hardware install routing without modifying the host.
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
target="$tmp/target"
bin="$tmp/bin"
pci="$tmp/pci"
mkdir -p "$target/etc/apk" "$target/lib/modules/6.12.20-0-lts" \
    "$bin" "$pci/0000:01:00.0" "$pci/0000:02:00.0"
printf 'alpine-base\n' > "$target/etc/apk/world"
printf '%s\n' 'vendor_id : AuthenticAMD' > "$tmp/cpuinfo"
printf '%s\n' 0x030000 > "$pci/0000:01:00.0/class"
printf '%s\n' 0x1002 > "$pci/0000:01:00.0/vendor"
printf '%s\n' 0x030200 > "$pci/0000:02:00.0/class"
printf '%s\n' 0x10de > "$pci/0000:02:00.0/vendor"

cat > "$bin/mountpoint" <<'MOCK'
#!/bin/sh
exit 0
MOCK
cat > "$bin/findmnt" <<'MOCK'
#!/bin/sh
printf '%s\n' ext4
MOCK
cat > "$bin/chroot" <<'MOCK'
#!/bin/sh
set -eu
target=$1
shift
printf '%s\n' "$*" >> "$VEYRA_HARDWARE_TEST_LOG"
case "$1" in
    apk)
        [ "$2" = add ] && [ "$3" = --no-cache ] || {
            echo "Unexpected target APK command: $*" >&2
            exit 1
        }
        shift 3
        printf '%s\n' "$*" > "$VEYRA_HARDWARE_TEST_PACKAGES"
        ;;
    mkinitfs)
        [ -n "$2" ] || exit 1
        grep -q 'features=.*ext4 virtio nvme' "$target/etc/mkinitfs/mkinitfs.conf"
        ;;
    *)
        echo "Unexpected chroot command: $*" >&2
        exit 1
        ;;
esac
MOCK
cat > "$bin/lspci" <<'MOCK'
#!/bin/sh
printf '%s\n' '01:00.0 VGA compatible controller: AMD/ATI' '02:00.0 3D controller: NVIDIA'
MOCK
cat > "$bin/lsusb" <<'MOCK'
#!/bin/sh
printf '%s\n' 'Bus 001 Device 001: Linux Foundation'
MOCK
chmod +x "$bin"/*

export PATH="$bin:$PATH"
export VEYRA_PCI_ROOT="$pci"
export VEYRA_CPUINFO="$tmp/cpuinfo"
export VEYRA_HARDWARE_TEST_LOG="$tmp/chroot.log"
export VEYRA_HARDWARE_TEST_PACKAGES="$tmp/packages.txt"
sh "$root/scripts/installer-hardware.sh" "$target"

for package in amd-ucode mesa-dri-gallium mesa-vulkan-ati \
    linux-firmware-amdgpu linux-firmware-radeon mesa-vulkan-nouveau \
    linux-firmware-nvidia; do
    grep -Fq "$package" "$tmp/packages.txt" || {
        echo "Detected package was not routed to the target APK transaction: $package" >&2
        exit 1
    }
done
grep -Fq 'apk add --no-cache' "$tmp/chroot.log"
grep -Fq 'mkinitfs 6.12.20-0-lts' "$tmp/chroot.log"
grep -q 'rootfstype=ext4' "$target/etc/default/grub"
grep -q 'AMD' "$target/var/log/veyra/hardware-detected.txt"
grep -q 'NVIDIA' "$target/var/log/veyra/hardware-detected.txt"
grep -q 'linux-firmware-nvidia' "$target/var/log/veyra/hardware-packages.txt"
echo 'Installer hardware routing and target initramfs configuration passed'
