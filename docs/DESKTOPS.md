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

The hardware detector inspects CPU vendor and PCI display-class devices, including multi-GPU machines. On Intel it selects Intel microcode and Mesa/Intel firmware; AMD uses AMD microcode and Radeon/Mesa; NVIDIA uses Mesa Nouveau and NVIDIA firmware. NVIDIA proprietary modules are **not** offered, since Alpine's musl stable repositories do not provide a matching supported proprietary package.

**A network connection is required** for desktops other than Plasma and for any required packages not already available in the installed target. Missing packages or network errors abort the install rather than claiming success. Install packages are installed from signed official Alpine v3.22 main/community repositories; the installer does not add Alpine edge or run random vendor scripts.

## Verification

The build pipeline validates the chooser config and hardware selection against simulated PCI/CPU fixtures. Full hardware driver loading and disk-install/reboot testing are separate work and must be completed before Veyra is offered as a stable installer. Only test experimental disk installation on a blank disposable virtual disk.
