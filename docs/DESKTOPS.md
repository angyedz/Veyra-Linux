# Simple graphical installation

Veyra uses Calamares. Choose your language and keyboard, select a desktop environment (default: Plasma), choose a disk and create your user account. Installation downloads packages for the chosen desktop and automatically prepares graphics drivers and CPU microcode from Alpine's pinned repositories.

## Available desktops

| Choice | Display system | Login manager |
| --- | --- | --- |
| KDE Plasma (default) | Wayland | SDDM |
| GNOME | Wayland | GDM |
| Xfce | X11 | LightDM |
| LXQt | X11 | SDDM |

Calamares' `packagechooser` uses one required choice stored in `packagechooser_desktop`. The install phase passes that value to an allowlisted desktop installer script. The graphical live session remains Plasma, regardless of the desktop installed on disk.

The installer scans every PCI display-class device in the live system, so an integrated GPU plus one or more discrete GPUs gets the union of the matching package sets. The kernel drivers come from the installed `linux-lts` kernel; hardware detection selects Mesa's user-space drivers, GPU firmware and CPU microcode from signed Alpine repositories.

| Detected GPU | Kernel driver in `linux-lts` | Selected graphics support |
| --- | --- | --- |
| Intel | `i915` or `xe`, depending on GPU generation | Mesa Gallium, Vulkan ANV, `i915`/`xe` firmware, modern `iHD` and legacy `i965` VA-API |
| AMD | `radeon` or `amdgpu`, depending on GPU generation | Mesa Gallium, Vulkan RADV and VA-API where supported, AMD GPU firmware |
| NVIDIA | Nouveau | Mesa Nouveau, Vulkan NVK and VA-API where supported, NVIDIA firmware |
| Virtual GPU | Kernel's virtual display driver when available | Mesa Gallium; software rendering remains available |
| Other/unknown PCI GPU | Kernel driver when available | Generic Mesa path; no vendor-specific acceleration package is assumed |

CPU microcode follows the CPU vendor independently of the GPU choice. The proprietary NVIDIA kernel driver is not offered by Alpine's pinned musl repositories. Package selection alone cannot guarantee that every GPU model supports Vulkan or accelerated rendering; the installer records detected hardware and selected packages, and real-device qualification remains a separate gate.

**A network connection is required** for desktops other than Plasma and for any required packages not already available in the installed target. Missing packages or network errors abort the install rather than claiming success. Install packages are installed from signed official Alpine v3.22 main/community repositories; the installer does not add Alpine edge or run random vendor scripts.

## Verification

The build pipeline validates Intel, AMD, Nouveau, virtual, unknown and hybrid PCI/CPU fixtures and checks the selected package names against Alpine v3.22 repositories. Full hardware driver loading and disk-install/reboot testing are separate work and must be completed before Veyra is offered as a stable installer. Only test experimental disk installation on a blank disposable virtual disk.
