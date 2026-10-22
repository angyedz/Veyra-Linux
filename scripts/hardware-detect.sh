#!/bin/sh
# Select Alpine firmware and Mesa packages for every PCI display device.
# Kernel DRM modules are supplied by linux-lts; this script adds firmware and
# userspace components to the installed target based on the LIVE machine.
set -eu
mode=${1:---packages}
pci_root=${VEYRA_PCI_ROOT:-/sys/bus/pci/devices}
cpuinfo=${VEYRA_CPUINFO:-/proc/cpuinfo}

cpu_vendor=unknown
if [ -r "$cpuinfo" ]; then
    cpu_vendor=$(awk -F: '/^vendor_id[[:space:]]*:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$cpuinfo")
    [ -n "$cpu_vendor" ] || cpu_vendor=unknown
fi

case "$mode" in
    --report)
        printf 'CPU: %s\n' "$cpu_vendor"
        gpu_found=0
        nvidia_found=0
        for class_file in "$pci_root"/*/class; do
            [ -r "$class_file" ] || continue
            IFS= read -r device_class < "$class_file" || true
            case "$device_class" in 0x03*) ;; *) continue ;; esac
            device_dir=$(dirname "$class_file")
            bdf=$(basename "$device_dir")
            gpu_found=1
            vendor_file="$device_dir/vendor"
            if [ ! -r "$vendor_file" ]; then
                printf 'Graphics: %s PCI display device has no readable vendor ID; generic Mesa fallback only.\n' "$bdf"
                continue
            fi
            IFS= read -r vendor < "$vendor_file" || true
            [ -n "$vendor" ] || vendor=unknown
            case "$vendor" in
                0x8086)
                    printf 'Graphics: %s Intel — linux-lts i915/xe; Mesa Gallium and Vulkan ANV; iHD/i965 VA-API; i915/xe firmware.\n' "$bdf"
                    ;;
                0x1002)
                    printf 'Graphics: %s AMD — linux-lts amdgpu/radeon; Mesa RadeonSI, RADV and VA-API where supported; AMD GPU firmware.\n' "$bdf"
                    ;;
                0x10de)
                    printf 'Graphics: %s NVIDIA — linux-lts Nouveau; Mesa nouveau, NVK and VA-API where supported; NVIDIA firmware.\n' "$bdf"
                    nvidia_found=1
                    ;;
                0x1af4|0x1234|0x15ad|0x1b36)
                    printf 'Graphics: %s virtual GPU — linux-lts virtual display support; Mesa Gallium/software fallback.\n' "$bdf"
                    ;;
                *)
                    printf 'Graphics: %s PCI vendor %s — no vendor-specific package mapping; linux-lts/Mesa support depends on this device.\n' "$bdf" "$vendor"
                    ;;
            esac
        done
        if [ "$gpu_found" -eq 0 ]; then
            echo 'Graphics: no PCI display-class device found.'
        fi
        case "$cpu_vendor" in
            GenuineIntel) echo 'CPU microcode: intel-ucode' ;;
            AuthenticAMD) echo 'CPU microcode: amd-ucode' ;;
        esac
        if [ "$nvidia_found" -eq 1 ]; then
            echo 'NVIDIA uses the open-source Nouveau stack; Alpine v3.22 does not provide the proprietary NVIDIA kernel driver.'
        fi
        echo 'OpenGL/Vulkan acceleration depends on the detected GPU model; Mesa llvmpipe/swrast remains the fallback.'
        ;;
    --packages)
        {
            case "$cpu_vendor" in
                GenuineIntel) echo intel-ucode ;;
                AuthenticAMD) echo amd-ucode ;;
            esac
            for class_file in "$pci_root"/*/class; do
                [ -r "$class_file" ] || continue
                IFS= read -r device_class < "$class_file" || true
                case "$device_class" in 0x03*) ;; *) continue ;; esac
                vendor_file="$(dirname "$class_file")/vendor"
                if [ ! -r "$vendor_file" ]; then
                    # Keep a usable software-rendering path if PCI metadata is
                    # incomplete; the kernel driver remains hardware-specific.
                    echo mesa-dri-gallium
                    continue
                fi
                IFS= read -r vendor < "$vendor_file" || true
                case "$vendor" in
                    0x8086)
                        printf '%s\n' mesa-dri-gallium mesa-vulkan-intel \
                            linux-firmware-i915 linux-firmware-xe \
                            intel-media-driver libva-intel-driver
                        ;;
                    0x1002)
                        printf '%s\n' mesa-dri-gallium mesa-vulkan-ati \
                            mesa-va-gallium \
                            linux-firmware-amdgpu linux-firmware-radeon
                        ;;
                    0x10de)
                        printf '%s\n' mesa-dri-gallium mesa-vulkan-nouveau \
                            mesa-va-gallium \
                            linux-firmware-nvidia
                        ;;
                    0x1af4|0x1234|0x15ad|0x1b36)
                        echo mesa-dri-gallium
                        ;;
                    *)
                        # Unknown vendors get generic Mesa only, never a
                        # guessed firmware or vendor-specific driver package.
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
