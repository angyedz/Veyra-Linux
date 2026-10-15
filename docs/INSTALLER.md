# Graphical installer development

Veyra is integrating Calamares 3.3.15 with Qt6 and a native Alpine package. The pinned source is built from the archived upstream Calamares project in `packaging/calamares/APKBUILD`.

The `Build Calamares` workflow compiles the native package independently of ISO builds while compatibility is being validated. It does not yet mean the program can install the distribution end-to-end.

The live KDE desktop includes a launcher named **Install Veyra Linux**. Until the binary and a distribution-specific settings/modules configuration have passed installation tests, the launcher reports that the installer is unavailable; it never pretends to install the OS.

A complete installer must handle GPT/EFI and BIOS bootloaders, partitioning, user creation, Alpine packages/keys/repositories, OpenRC services and kernel/initramfs configuration. Never test on a disk containing important data; use a blank QEMU virtual disk.
