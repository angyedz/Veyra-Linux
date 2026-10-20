# Plasma session and hardware

Veyra currently installs **KDE Plasma only**, using SDDM. Calamares and the text installer do not offer alternative desktop choices; the install script rejects any desktop ID other than `plasma`. This keeps the installed desktop aligned with the KDE-based Live ISO.

## Hardware preparation

The installer inspects CPU vendor and PCI display-class devices, including multi-GPU machines. On Intel it selects Intel microcode and Mesa/Intel firmware; AMD uses AMD microcode and Radeon/Mesa; NVIDIA uses Mesa Nouveau and NVIDIA firmware. NVIDIA proprietary modules are **not** offered, since Alpine's musl stable repositories do not provide a matching supported proprietary package.

The target is prepared from signed official Alpine v3.22 main/community repositories. The installer does not add Alpine edge or run vendor scripts. Network access is required for target-system packages and firmware.

## Live privileges

The disposable Live ISO grants the autologged `veyra` account passwordless `sudo` and active-session Polkit authorization so administrative tools do not prompt for a password during the Live session. The installer removes both policies before configuring the installed system. These broad Live privileges are not copied into the installed OS.

## Verification

CI validates the Plasma-only routing and hardware selection against mocked PCI/CPU fixtures. The ISO workflow separately installs to and boots a blank QEMU disk. These checks do not establish physical hardware driver loading or release readiness; only test disk installation on a disposable virtual machine.
