#!/bin/sh
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/pci/0000:00:02.0" "$tmp/pci/0000:01:00.0"

printf '%s\n' 'vendor_id : GenuineIntel' > "$tmp/cpuinfo"
printf '%s\n' 0x030000 > "$tmp/pci/0000:00:02.0/class"
printf '%s\n' 0x8086 > "$tmp/pci/0000:00:02.0/vendor"
printf '%s\n' 0x030200 > "$tmp/pci/0000:01:00.0/class"
printf '%s\n' 0x10de > "$tmp/pci/0000:01:00.0/vendor"
VEYRA_CPUINFO="$tmp/cpuinfo" VEYRA_PCI_ROOT="$tmp/pci" \
    sh "$root/scripts/hardware-detect.sh" --packages > "$tmp/packages"
for pkg in intel-ucode mesa-vulkan-intel mesa-vulkan-nouveau linux-firmware-nvidia; do
    grep -qx "$pkg" "$tmp/packages" || { echo "Missing $pkg" >&2; exit 1; }
done
if [ "$(sort -u "$tmp/packages" | wc -l)" -ne "$(wc -l < "$tmp/packages")" ]; then
    echo 'Duplicate firmware packages' >&2
    exit 1
fi

printf '%s\n' 'vendor_id : AuthenticAMD' > "$tmp/cpuinfo"
printf '%s\n' 0x1002 > "$tmp/pci/0000:01:00.0/vendor"
VEYRA_CPUINFO="$tmp/cpuinfo" VEYRA_PCI_ROOT="$tmp/pci" \
    sh "$root/scripts/hardware-detect.sh" --packages > "$tmp/packages"
for pkg in amd-ucode mesa-vulkan-ati linux-firmware-amdgpu; do
    grep -qx "$pkg" "$tmp/packages" || { echo "Missing $pkg" >&2; exit 1; }
done

printf '%s\n' 'vendor_id : UnknownVendor' > "$tmp/cpuinfo"
printf '%s\n' 0x020000 > "$tmp/pci/0000:00:02.0/class"
printf '%s\n' 0x020000 > "$tmp/pci/0000:01:00.0/class"
VEYRA_CPUINFO="$tmp/cpuinfo" VEYRA_PCI_ROOT="$tmp/pci" \
    sh "$root/scripts/hardware-detect.sh" --packages > "$tmp/packages"
test ! -s "$tmp/packages"
echo 'Hardware detection fixtures passed'
