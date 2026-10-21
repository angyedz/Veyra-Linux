# Simple graphical installation

Veyra uses Calamares. Choose your language and keyboard, select Plasma (default), GNOME, Xfce, LXQt, or a console-only system, choose a disk, and create your user account. Installation downloads packages for the chosen desktop and automatically prepares graphics drivers and CPU microcode from Alpine's pinned repositories.

## Available desktops

| Choice | Display system | Login manager |
| --- | --- | --- |
| KDE Plasma (default) | Wayland | SDDM |
| GNOME | Wayland | GDM |
| Xfce | X11 | LightDM |
| LXQt | X11 | SDDM |
| Minimal (console only) | Text console | None |

The user-facing Calamares wizard installs Plasma without asking the user to choose a desktop. The other profiles remain available to scripted installs and automated compatibility checks; they are not offered in the graphical wizard.

The hardware detector inspects CPU vendor and PCI display-class devices, including multi-GPU machines. On Intel it selects Intel microcode and Mesa/Intel firmware; AMD uses AMD microcode and Radeon/Mesa; NVIDIA uses Mesa Nouveau and NVIDIA firmware. NVIDIA proprietary modules are **not** offered, since Alpine's musl stable repositories do not provide a matching supported proprietary package.

**A network connection is required** for desktops other than Plasma and for any required packages not already available in the installed target. Missing packages or network errors abort the install rather than claiming success. Install packages are installed from signed official Alpine v3.22 main/community repositories; the installer does not add Alpine edge or run random vendor scripts.

## Verification

CI validates chooser configuration, hardware selection against simulated PCI/CPU fixtures, and package availability. Its QEMU matrix installs all five choices on blank BIOS disks and also tests Plasma and the console-only profile with UEFI, then checks first boot. These tests drive the installer scripts directly; physical GPU driver loading and the Calamares GUI flow remain untested. Only test experimental disk installation on a blank disposable virtual disk.
