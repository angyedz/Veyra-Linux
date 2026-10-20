# Graphical installer development

Veyra is integrating Calamares 3.3.15 with Qt6 and a native Alpine package. The pinned source is built from the archived upstream Calamares project in `packaging/calamares/APKBUILD`.

The Veyra ISO workflow first builds a native Calamares package and then includes that signed package in the ISO. The separate **Build Calamares** workflow may be started manually. CI installs all five desktop choices onto fresh BIOS QEMU disks and also tests Plasma and the console-only profile with UEFI. It verifies first boot by serial console. This exercises the same Veyra installer scripts Calamares calls, but does not click through the Calamares GUI or its partitioning screens.

The live KDE desktop includes **Install Veyra Linux** (Calamares) and **Install Veyra Linux (text mode)**. Calamares preserves the live Wayland/X11 display environment when it starts with elevated privileges. It asks for language, keyboard, disk layout and a user account; Plasma is installed automatically. The text installer uses a short guided flow for a whole-drive ext4 install, with explicit erase confirmation and automatic UEFI/BIOS setup. It is available from the KDE menu or by running `sudo veyra-install-tui` in a terminal. The QEMU matrix uses disposable blank disks for MBR/BIOS and GPT/UEFI.

A complete installer must handle GPT/EFI and BIOS bootloaders, partitioning, user creation, Alpine packages/keys/repositories, OpenRC services and kernel/initramfs configuration. Never test on a disk containing important data; use a blank QEMU virtual disk.

## One-screen choices

Both installers set up **KDE Plasma** automatically. Calamares starts without requiring existing partitions, so a new or blank drive can be installed; it offers **Erase disk** or **Manual partitioning**. The text installer is optimized for a new user: it selects the firmware mode, offers only available unmounted drives, asks for an account and password, then summarizes the exact drive before erasing it. It creates a standard ext4 layout and configures boot files and detected hardware. Alternative desktop profiles remain available to scripted tests, not as user-facing choices. A working network connection is checked before either install begins.

After copying the Alpine live root, Veyra configures Plasma and reads the live system's PCI hardware and CPU vendor. It installs the matching Mesa components, firmware and microcode from signed Alpine repositories, then Calamares completes user setup and bootloader configuration. NVIDIA currently uses Nouveau, not the unavailable proprietary Linux driver on musl.

See [Desktop selection and hardware](DESKTOPS.md) for development details. Automated configuration, package-resolution, and detection checks do not replace testing the Calamares GUI or installing on physical hardware.

The installer re-extracts the on-disk kernel/modules from Alpine (the live ISO uses a separate modloop image) and regenerates the installed initramfs after firmware selection. The QEMU install path verifies the resulting kernel, initramfs, GRUB configuration, and first boot for ext4. GUI-driven installation and filesystems other than ext4 are not covered.

The ISO intentionally omits GRUB from the RAM-backed live package set: its configuration trigger needs a real disk root, and attempting it in diskless mode left a persistent APK transaction error. The installer installs signed Alpine GRUB packages only after mounting the destination root.

## Filesystem boot fix

The first full QEMU installation copied the system and installed GRUB, but the installed system fell into Alpine's emergency recovery shell when mounting `/dev/vda1` at `/sysroot`. Alpine only eagerly loads the root filesystem driver if `rootfstype=` is set. Veyra detects the destination's actual ext4/Btrfs/XFS/F2FS type, adds it to the installed mkinitfs features alongside VirtIO/NVMe, and appends `rootfstype=` to GRUB's kernel options. CI checks the ext4 path by booting installed QEMU guests. Other filesystems remain unverified.
