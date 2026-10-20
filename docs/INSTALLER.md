# Graphical installer development

Veyra is integrating Calamares 3.3.15 with Qt6 and a native Alpine package. The pinned source is built from the archived upstream Calamares project in `packaging/calamares/APKBUILD`.

The Veyra ISO workflow first builds a native Calamares package and then includes that signed package in the ISO. The separate **Build Calamares** workflow may be started manually. A successful package build does not establish that installation to disk works end-to-end.

The live KDE desktop includes a launcher named **Install Veyra Linux**. It starts Calamares with the current X11/Wayland display credentials, records startup output under `~/.cache/veyra-calamares.log`, and offers the guided text installer if Calamares fails. Veyra's module configuration lives under `calamares/` and includes partition selection, copying the diskless live root to the target filesystem, creating a user, configuring OpenRC services and installing GRUB. These steps **must be validated on a disposable blank virtual disk before use on physical hardware**.

A complete installer must handle GPT/EFI and BIOS bootloaders, partitioning, user creation, Alpine packages/keys/repositories, OpenRC services and kernel/initramfs configuration. Never test on a disk containing important data; use a blank QEMU virtual disk.

## KDE-only installation

The graphical and text installers install **KDE Plasma with SDDM only**. Calamares does not show a desktop chooser, and the desktop setup script refuses unknown or non-Plasma selections. Installation requires working repository connectivity and checks for this before partitioning.

After copying the Alpine live root, Veyra reads the live system's PCI hardware and CPU vendor. It installs the matching Mesa components, firmware and microcode from signed Alpine repositories, then Calamares completes user setup and bootloader configuration. NVIDIA currently uses Nouveau, not the unavailable proprietary Linux driver on musl.

## Live-session privileges

The disposable Live ISO gives the autologged `veyra` user passwordless `sudo` access and active-session Polkit authorization, so administrative tools work without password prompts. `installer-prepare.sh` removes both grants before the installed system is configured. The installed system keeps its normal account-password policy.

See [Plasma session and hardware](DESKTOPS.md) for development details. Automated config, package resolution and detection checks do **not** replace an end-to-end installation to a blank VM.

The installer re-extracts the on-disk kernel/modules from Alpine (the live ISO uses a separate modloop image) and regenerates the installed initramfs after firmware selection. This path is still awaiting a full installation-and-reboot check in QEMU.

The ISO intentionally omits GRUB from the RAM-backed live package set: its configuration trigger needs a real disk root, and attempting it in diskless mode left a persistent APK transaction error. The installer installs signed Alpine GRUB packages only after mounting the destination root.

## Filesystem boot fix

The first full QEMU installation successfully copied the system, installed GRUB and generated an initramfs, but the installed system fell into Alpine's emergency recovery shell when mounting `/dev/vda1` at `/sysroot`. Alpine only eagerly loads the root filesystem driver if `rootfstype=` is set. Veyra now detects the destination's actual ext4/Btrfs/XFS/F2FS type, adds it to the installed mkinitfs features alongside VirtIO/NVMe, and appends `rootfstype=` to GRUB's kernel options. This is applied to the installed system only. A complete reboot test is still required to confirm the fix.
