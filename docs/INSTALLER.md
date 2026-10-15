# Graphical installer development

Veyra is integrating Calamares 3.3.15 with Qt6 and a native Alpine package. The pinned source is built from the archived upstream Calamares project in `packaging/calamares/APKBUILD`.

The Veyra ISO workflow first builds a native Calamares package and then includes that signed package in the ISO. The separate **Build Calamares** workflow may be started manually. A successful package build does not establish that installation to disk works end-to-end.

The live KDE desktop includes a launcher named **Install Veyra Linux**. The launcher opens Calamares when the package is available. Veyra's module configuration lives under `calamares/` and includes partition selection, copying the diskless live root to the target filesystem, creating a user, configuring OpenRC services and installing GRUB. These steps **must be validated on a disposable blank virtual disk before use on physical hardware**.

A complete installer must handle GPT/EFI and BIOS bootloaders, partitioning, user creation, Alpine packages/keys/repositories, OpenRC services and kernel/initramfs configuration. Never test on a disk containing important data; use a blank QEMU virtual disk.

## One-screen choices

The wizard now provides a single required desktop choice: **KDE Plasma** (default), **GNOME**, **Xfce** or **LXQt**. The live system keeps Plasma, but the installed system is configured with only the selected desktop and its login manager. Installation requires working repository connectivity and checks for this before partitioning.

After copying the Alpine live root, Veyra configures that desktop and reads the live system's PCI hardware and CPU vendor. It installs the matching Mesa components, firmware and microcode from signed Alpine repositories, then Calamares completes user setup and bootloader configuration. NVIDIA currently uses Nouveau, not the unavailable proprietary Linux driver on musl.

See [Desktop selection and hardware](DESKTOPS.md) for development details. Automated config, package resolution and detection checks do **not** replace an end-to-end installation to a blank VM.
