# Plasma session and hardware

Veyra currently installs **KDE Plasma only**, using SDDM. Calamares and the text installer do not offer alternative desktop choices; the install script rejects any desktop ID other than `plasma`. This keeps the installed desktop aligned with the KDE-based Live ISO.

## Hardware preparation

The installed system uses Alpine's `linux-lts` kernel and the full `linux-firmware` meta package, which supplies the firmware subpackages for common storage, network, audio and graphics devices. The kernel loads matching modules through normal device discovery. Veyra additionally inspects CPU vendor and every PCI display adapter, including mixed-GPU machines: Intel selects Intel microcode and Mesa/Intel components, AMD selects AMD microcode and Radeon/Mesa, and NVIDIA selects Nouveau/Mesa. NVIDIA proprietary modules are **not** offered, since Alpine's musl stable repositories do not provide a matching supported proprietary package.

The installer saves `lspci -nnk`, `lsusb` and the USB driver tree under `/var/log/veyra/` for hardware troubleshooting. This broad firmware and kernel-module set cannot guarantee support for every device model; physical hardware checks are still needed, especially for newer Wi-Fi adapters and proprietary devices.

The target is prepared from signed official Alpine v3.22 main/community repositories. The installer does not add Alpine edge or run vendor scripts. Network access is required for target-system packages and firmware.

## Live privileges

The disposable Live ISO grants the autologged `veyra` account passwordless `sudo` and active-session Polkit authorization so administrative tools do not prompt for a password during the Live session. The installer removes both policies before configuring the installed system. These broad Live privileges are not copied into the installed OS.

## Verification

CI validates the Plasma-only routing and vendor-specific GPU selection against mocked PCI/CPU fixtures. The ISO workflow separately installs to and boots a blank QEMU disk. These checks do not establish physical hardware driver loading or release readiness; only test disk installation on a disposable virtual machine.
