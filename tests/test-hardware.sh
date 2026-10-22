#!/bin/sh
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
pci="$tmp/pci"
cpuinfo="$tmp/cpuinfo"

reset_fixture() {
    rm -rf "$pci"
    mkdir -p "$pci"
}
add_gpu() {
    slot=$1
    class=$2
    vendor=$3
    mkdir -p "$pci/0000:$slot"
    printf '%s\n' "$class" > "$pci/0000:$slot/class"
    printf '%s\n' "$vendor" > "$pci/0000:$slot/vendor"
}
detect() {
    VEYRA_CPUINFO="$cpuinfo" VEYRA_PCI_ROOT="$pci" \
        sh "$root/scripts/hardware-detect.sh" --packages > "$tmp/packages"
}
assert_has() {
    grep -qx "$1" "$tmp/packages" || { echo "Missing $1" >&2; exit 1; }
}
assert_lacks() {
    if grep -qx "$1" "$tmp/packages"; then
        echo "Unexpected package $1" >&2
        exit 1
    fi
}
assert_unique() {
    [ "$(sort -u "$tmp/packages" | wc -l)" -eq "$(wc -l < "$tmp/packages")" ] || {
        echo 'Duplicate hardware packages' >&2
        exit 1
    }
}

# Hybrid Intel/NVIDIA laptop: both adapters and CPU microcode must be selected.
reset_fixture
printf '%s\n' 'vendor_id : GenuineIntel' > "$cpuinfo"
add_gpu 00:02.0 0x030000 0x8086
add_gpu 01:00.0 0x030200 0x10de
detect
for pkg in intel-ucode mesa-dri-gallium mesa-vulkan-intel \
    linux-firmware-i915 linux-firmware-xe intel-media-driver \
    libva-intel-driver mesa-vulkan-nouveau mesa-va-gallium \
    linux-firmware-nvidia; do
    assert_has "$pkg"
done
assert_lacks linux-firmware-amdgpu
assert_unique
VEYRA_CPUINFO="$cpuinfo" VEYRA_PCI_ROOT="$pci" \
    sh "$root/scripts/hardware-detect.sh" --report > "$tmp/report"
grep -q 'Intel' "$tmp/report"
grep -q 'NVIDIA' "$tmp/report"
grep -q 'Nouveau' "$tmp/report"

# AMD discrete/integrated graphics uses the RadeonSI/RADV stack and firmware.
reset_fixture
printf '%s\n' 'vendor_id : AuthenticAMD' > "$cpuinfo"
add_gpu 03:00.0 0x030000 0x1002
detect
for pkg in amd-ucode mesa-dri-gallium mesa-vulkan-ati mesa-va-gallium \
    linux-firmware-amdgpu linux-firmware-radeon; do
    assert_has "$pkg"
done
assert_lacks mesa-vulkan-nouveau
assert_lacks linux-firmware-nvidia
assert_unique

# Intel-only graphics gets both generation firmware packages and Vulkan.
reset_fixture
printf '%s\n' 'vendor_id : GenuineIntel' > "$cpuinfo"
add_gpu 00:02.0 0x030000 0x8086
detect
for pkg in intel-ucode mesa-dri-gallium mesa-vulkan-intel \
    linux-firmware-i915 linux-firmware-xe intel-media-driver \
    libva-intel-driver; do
    assert_has "$pkg"
done
assert_lacks mesa-vulkan-ati
assert_lacks mesa-vulkan-nouveau

# A mixed AMD/NVIDIA system receives both driver stacks without duplicates.
reset_fixture
printf '%s\n' 'vendor_id : AuthenticAMD' > "$cpuinfo"
add_gpu 01:00.0 0x030000 0x1002
add_gpu 02:00.0 0x030200 0x10de
detect
for pkg in amd-ucode mesa-vulkan-ati mesa-vulkan-nouveau mesa-va-gallium \
    linux-firmware-amdgpu linux-firmware-nvidia; do
    assert_has "$pkg"
done
assert_unique

# Virtual GPUs keep the generic Gallium/software path; a non-display PCI
# device must never trigger a graphics package selection.
reset_fixture
printf '%s\n' 'vendor_id : UnknownVendor' > "$cpuinfo"
add_gpu 00:01.0 0x020000 0x10de
add_gpu 00:02.0 0x030000 0x1af4
detect
assert_has mesa-dri-gallium
assert_lacks mesa-vulkan-nouveau
assert_lacks linux-firmware-nvidia
VEYRA_CPUINFO="$cpuinfo" VEYRA_PCI_ROOT="$pci" \
    sh "$root/scripts/hardware-detect.sh" --report > "$tmp/report"
grep -q 'virtual GPU' "$tmp/report"

# Unknown vendors and incomplete PCI metadata get generic Mesa only.
reset_fixture
printf '%s\n' 'vendor_id : UnknownVendor' > "$cpuinfo"
add_gpu 00:03.0 0x030000 0x9999
detect
assert_has mesa-dri-gallium
[ "$(wc -l < "$tmp/packages")" -eq 1 ]
VEYRA_CPUINFO="$cpuinfo" VEYRA_PCI_ROOT="$pci" \
    sh "$root/scripts/hardware-detect.sh" --report > "$tmp/report"
grep -q 'no vendor-specific package mapping' "$tmp/report"
assert_unique

reset_fixture
printf '%s\n' 'vendor_id : UnknownVendor' > "$cpuinfo"
mkdir -p "$pci/0000:00:04.0"
printf '%s\n' 0x030000 > "$pci/0000:00:04.0/class"
detect
assert_has mesa-dri-gallium
[ "$(wc -l < "$tmp/packages")" -eq 1 ]
VEYRA_CPUINFO="$cpuinfo" VEYRA_PCI_ROOT="$pci" \
    sh "$root/scripts/hardware-detect.sh" --report > "$tmp/report"
grep -q 'no readable vendor ID; generic Mesa fallback only' "$tmp/report"

# CPU-only/no recognized vendor keeps a clean empty package list and explains
# that no PCI graphics device was found.
reset_fixture
printf '%s\n' 'vendor_id : UnknownVendor' > "$cpuinfo"
detect
test ! -s "$tmp/packages"
VEYRA_CPUINFO="$cpuinfo" VEYRA_PCI_ROOT="$pci" \
    sh "$root/scripts/hardware-detect.sh" --report > "$tmp/report"
grep -q 'no PCI display-class device found' "$tmp/report"

echo 'Hardware detection fixtures passed'
