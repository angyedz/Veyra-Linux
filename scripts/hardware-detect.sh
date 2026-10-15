#!/bin/sh
# Only prints distro package names or readable detected hardware data.
# The hardware comes from the LIVE machine, not the target chroot.
set -eu
mode="${1:---packages}"
pci_root="${VEYRA_PCI_ROOT:-/sys/bus/pci/devices}"
cpuinfo="${VEYRA_CPUINFO:-/proc/cpuinfo}"

cpu_vendor=unknown
if [ -r "$cpuinfo" ]; then
    cpu_vendor=$(awk -F: '/^vendor_id[[:space:]]*:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$cpuinfo")
    [ -n "$cpu_vendor" ] || cpu_vendor=unknown
fi

gpu_vendors=
for class_file in "$pci_root"/*/class; do
    [ -r "$class_file" ] || continue
    IFS= read -r device_class < "$class_file" || true
    case "$device_class" in
        0x03*) ;;
        *) continue ;;
    esac
    vendor_file="${class_file%/class}/vendor"
    [ -r "$vendor_file" ] || continue
    IFS= read -r vendor < "$vendor_file" || true
    case "$vendor" in
        0x8086) gpu_vendors="$gpu_vendors intel" ;;
        0x1002) gpu_vendors="$gpu_vendors amd" ;;
        0x10de) gpu_vendors="$gpu_vendors nvidia" ;;
        0x1af4|0x1234|0x15ad) gpu_vendors="$gpu_vendors virtual" ;;
        *) gpu_vendors="$gpu_vendors unknown" ;;
    esac
done

case "$mode" in
    --report)
        printf 'CPU: %s\n' "$cpu_vendor"
        printf 'Graphics:%s\n' "${gpu_vendors:- unknown}"
        if printf ' %s ' "$gpu_vendors" | grep -q ' nvidia '; then
            echo 'NVIDIA: Alpine uses the open-source Nouveau driver (not proprietary NVIDIA).'
        fi
        ;;
    --packages)
        {
            case "$cpu_vendor" in
                GenuineIntel) echo intel-ucode ;;
                AuthenticAMD) echo amd-ucode ;;
            esac
            for vendor in $gpu_vendors; do
                case "$vendor" in
                    amd)
                        printf '%s\n' mesa-dri-gallium mesa-vulkan-ati \
                            linux-firmware-amdgpu linux-firmware-radeon
                        ;;
                    intel)
                        printf '%s\n' mesa-dri-gallium mesa-vulkan-intel \
                            linux-firmware-i915 linux-firmware-xe intel-media-driver
                        ;;
                    nvidia)
                        # Official NVIDIA driver is not available for musl Alpine.
                        printf '%s\n' mesa-dri-gallium mesa-vulkan-nouveau \
                            linux-firmware-nvidia
                        ;;
                    virtual)
                        echo mesa-dri-gallium
                        ;;
                esac
            done
        } | sort -u
        ;;
    *)
        echo "Usage: hardware-detect.sh [--packages|--report]" >&2
        exit 2
        ;;
esac
