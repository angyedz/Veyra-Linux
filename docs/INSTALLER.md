# Graphical installer development

Veyra is integrating Calamares 3.3.15 with Qt6 and a native Alpine package. The pinned source is built from the archived upstream Calamares project in `packaging/calamares/APKBUILD`.

The Veyra ISO workflow first builds a native Calamares package and then includes that signed package in the ISO. The separate **Build Calamares** workflow may be started manually. A successful package build does not establish that installation to disk works end-to-end.

The live KDE desktop includes a launcher named **Install Veyra Linux**. The launcher opens Calamares when the package is available. Veyra's module configuration lives under `calamares/` and includes partition selection, copying the diskless live root to the target filesystem, creating a user, configuring OpenRC services and installing GRUB. These steps **must be validated on a disposable blank virtual disk before use on physical hardware**.

A complete installer must handle GPT/EFI and BIOS bootloaders, partitioning, user creation, Alpine packages/keys/repositories, OpenRC services and kernel/initramfs configuration. Never test on a disk containing important data; use a blank QEMU virtual disk.
