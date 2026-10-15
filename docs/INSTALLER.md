# Graphical installer development

Veyra is integrating Calamares 3.3.15 with Qt6 and a native Alpine package. The pinned source is built from the archived upstream Calamares project in `packaging/calamares/APKBUILD`.

The Veyra ISO workflow first builds a native Calamares package and then includes that signed package in the ISO. The separate **Build Calamares** workflow may be started manually. CI installs all five desktop choices onto fresh BIOS QEMU disks and also tests Plasma and the console-only profile with UEFI. It verifies first boot by serial console. This exercises the same Veyra installer scripts Calamares calls, but does not click through the Calamares GUI or its partitioning screens.

The live KDE desktop includes a launcher named **Install Veyra Linux**. The launcher opens Calamares when the package is available. Veyra's module configuration lives under `calamares/` and includes partition selection, copying the diskless live root to the target filesystem, creating a user, configuring OpenRC services and installing GRUB. The QEMU matrix uses disposable blank disks for MBR/BIOS and GPT/UEFI. The actual GUI sequence and physical hardware still need validation before broader use.

A complete installer must handle GPT/EFI and BIOS bootloaders, partitioning, user creation, Alpine packages/keys/repositories, OpenRC services and kernel/initramfs configuration. Never test on a disk containing important data; use a blank QEMU virtual disk.

## One-screen choices

The wizard provides one required system choice: **KDE Plasma** (default), **GNOME**, **Xfce**, **LXQt**, or a **console-only** system. The live system keeps Plasma, while the installed system is configured for only the selected desktop and login manager; console-only installs no display manager. Installation requires working repository connectivity and checks for this before partitioning.

After copying the Alpine live root, Veyra configures that desktop and reads the live system's PCI hardware and CPU vendor. It installs the matching Mesa components, firmware and microcode from signed Alpine repositories, then Calamares completes user setup and bootloader configuration. NVIDIA currently uses Nouveau, not the unavailable proprietary Linux driver on musl.

See [Desktop selection and hardware](DESKTOPS.md) for development details. Automated configuration, package-resolution, and detection checks do not replace testing the Calamares GUI or installing on physical hardware.

The installer re-extracts the on-disk kernel/modules from Alpine (the live ISO uses a separate modloop image) and regenerates the installed initramfs after firmware selection. The QEMU install path verifies the resulting kernel, initramfs, GRUB configuration, and first boot for ext4. GUI-driven installation and filesystems other than ext4 are not covered.

The ISO intentionally omits GRUB from the RAM-backed live package set: its configuration trigger needs a real disk root, and attempting it in diskless mode left a persistent APK transaction error. The installer installs signed Alpine GRUB packages only after mounting the destination root.

## Filesystem boot fix

The first full QEMU installation copied the system and installed GRUB, but the installed system fell into Alpine's emergency recovery shell when mounting `/dev/vda1` at `/sysroot`. Alpine only eagerly loads the root filesystem driver if `rootfstype=` is set. Veyra detects the destination's actual ext4/Btrfs/XFS/F2FS type, adds it to the installed mkinitfs features alongside VirtIO/NVMe, and appends `rootfstype=` to GRUB's kernel options. CI checks the ext4 path by booting installed QEMU guests. Other filesystems remain unverified.
