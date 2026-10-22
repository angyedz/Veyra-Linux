# Graphical installer development

Veyra is integrating Calamares 3.3.15 with Qt6 and a native Alpine package. The pinned source is built from the archived upstream Calamares project in `packaging/calamares/APKBUILD`.

The Veyra ISO workflow first builds a native Calamares package and then includes that signed package in the ISO. The separate **Build Calamares** workflow may be started manually. A successful package build does not establish that installation to disk works end-to-end.

The live KDE desktop includes a launcher named **Install Veyra Linux**. The launcher opens Calamares when the package is available. Veyra's module configuration lives under `calamares/` and includes partition selection, copying the diskless live root to the target filesystem, creating a user, configuring OpenRC services and installing GRUB. These steps **must be validated on a disposable blank virtual disk before use on physical hardware**.

A complete installer must handle GPT/EFI and BIOS bootloaders, partitioning, user creation, Alpine packages/keys/repositories, OpenRC services and kernel/initramfs configuration. Never test on a disk containing important data; use a blank QEMU virtual disk.

## One-screen choices

The wizard now provides a single required desktop choice: **KDE Plasma** (default), **GNOME**, **Xfce** or **LXQt**. The live system keeps Plasma, but the installed system is configured with only the selected desktop and its login manager. Installation requires working repository connectivity and checks for this before partitioning.

After copying the Alpine live root, Veyra configures that desktop and scans all PCI display-class devices, including hybrid systems. The installed `linux-lts` kernel supplies the kernel modules; the installer adds matching Mesa user-space drivers, firmware and CPU microcode from signed Alpine repositories. AMD selects RadeonSI/RADV support, Intel selects Mesa ANV plus `i915`/`xe` firmware, and NVIDIA selects Nouveau/NVK support. Virtual and unknown devices retain the generic Mesa software path. NVIDIA's proprietary driver is not offered by Alpine's pinned musl repositories. See [Desktop selection and hardware](DESKTOPS.md) for package mapping and support limits.

Automated config, package resolution and detection checks do **not** replace an end-to-end installation to a blank VM.

The installer re-extracts the on-disk kernel/modules from Alpine (the live ISO uses a separate modloop image) and regenerates the installed initramfs after firmware selection. This path is still awaiting a full installation-and-reboot check in QEMU.

The ISO intentionally omits GRUB from the RAM-backed live package set: its configuration trigger needs a real disk root, and attempting it in diskless mode left a persistent APK transaction error. The installer installs signed Alpine GRUB packages only after mounting the destination root.

## Filesystem boot fix

The first full QEMU installation successfully copied the system, installed GRUB and generated an initramfs, but the installed system fell into Alpine's emergency recovery shell when mounting `/dev/vda1` at `/sysroot`. Alpine only eagerly loads the root filesystem driver if `rootfstype=` is set. Veyra now detects the destination's actual ext4/Btrfs/XFS/F2FS type, adds it to the installed mkinitfs features alongside VirtIO/NVMe, and appends `rootfstype=` to GRUB's kernel options. This is applied to the installed system only. A complete reboot test is still required to confirm the fix.
