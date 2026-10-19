# Veyra Linux architecture — decision record (2026-10-19)

**Status: approved direction; incremental implementation. Not a claim that the current ISO or installed system is atomic.**

## Two different environments

1. **Veyra Live ISO** is a conventional, Alpine 3.22/musl/OpenRC, RAM-backed live environment with KDE Plasma, networking, Calamares, diagnostic tools and the Alpine APK bootstrap. It is **not an A/B system**. This makes the installer and rescue environment simple and keeps the existing QEMU ISO boot and installation path working.
2. **Installed Veyra Plasma edition** is the target for an **atomic, versioned OS**, where the kernel, initramfs, OpenRC services, Qt/KDE Frameworks, KWin, Plasma, portals, host PipeWire and native Mesa belong to one coherent **system deployment**. Plasma is installed from packages, but its *versions* are managed as part of the host deployment, not freely replaced in the running root.
3. **User data and applications** are outside the rollback boundary. `/home`, user Nix profiles and durable application state must survive switching between system deployments. Each deployment needs its own APK database and package world. A shared `/var/lib/apk` database would be incorrect.
4. **glenv** stays distinct from the host musl/KDE desktop: a shared, signed Debian glibc runtime is paired to each Veyra host deployment and mounted read-only for host and user environments. No glibc libraries replace the native musl system or KWin.
5. **Other desktops** can be future **separate images/editions**, not ad-hoc upgrades that remove the core Plasma packages from an atomic Plasma deployment. The existing non-atomic installer options remain functional during migration.

## Package manager

`vpkg` becomes Veyra's user-facing package manager, derived from and crediting upstream `apk-tools` (GPL-2.0-only). It must keep Alpine package format, signatures and dependency solver compatibility, including the trusted Veyra APK repository. Maintain the appropriate GPL-2.0-only source/patches and copyright notices.

* Initial development and **Live ISO bootstrap** keep genuine Alpine `apk` available until the replacement is feature-complete. Alpine base, mkinitfs, abuild and mkimage depend on it; deleting it now would break the installer.
* Prototype `vpkg-engine` builds directly from a **pinned apk-tools 2.14.x source** with explicit downstream changes, under a distinct binary name. It runs only in test/build environments until audits pass. This is not a finished forked system package.
* Future system package operations populate **a fresh inactive deployment** with an independent APK database; post-install scripts must not mutate the running host. Validation comes before the bootloader switch.
* `vpkg` also offers Nix user-profile operations, but these do **not** alter system images.

## Filesystem-neutral system deployments

**Filesystem choice belongs to the user.** Atomic system updates must not require Btrfs, snapshots, reflinks, subvolumes, CoW or special filesystem features. Veyra must support its installable Linux root filesystems (ext4, XFS, F2FS, Btrfs) without changing the guarantees for any one of them.

The conceptual storage contract is directories and separately managed persistent data, not Btrfs-specific structures:

```text
/mounted-store/                         # conventional mounted filesystem
  deployments/A/                        # isolated complete OS tree + APK DB
  deployments/B/                        # another isolated complete OS tree
  persistent/home/                       # preserved across OS rollbacks
  persistent/nix/                        # optional persistent Nix state
  persistent/shared/                     # carefully scoped persistent state
  boot-state/                            # boot coordinator-owned metadata
ESP (if UEFI)                            # separately managed as required
```

An inactive system deployment can be created using a **verified file copy**, with full filesystem metadata preservation, on any supported filesystem. On Btrfs an optimized backend may eventually use snapshots, but only as an optional performance optimization and never as a requirement. The source must be offline/quiescent and cannot include active /proc, /sys, /dev, /run, persistent /home or /nix mountpoints.

The filesystem-neutral staging prototype currently **does not perform boot switching or installed-root atomic updates**. Full atomicity additionally requires durable staging and verification, independently bootable A/B roots, authenticated kernel/initramfs/boot entries, recovery after power loss and a validated fallback. A simple directory rename alone is **not sufficient** to claim atomic boot, and a read-only mount alone does not prevent privileged changes to the underlying source.

The installer must permit users to keep choosing ext4, Btrfs, XFS or F2FS. It must not reformat, force Btrfs, or silently migrate an existing filesystem. A complete QEMU A → B → rollback A boot test on **at least ext4** is required before production activation; other supported filesystems need compatibility coverage too.

## Implementation gates

- [x] Non-atomic Live ISO and QEMU console installation into a disposable disk.
- [x] Experimental signed glenv per-host release pairing and read-only mounts.
- [x] Native apk-tools-derived vpkg engine prototype, tested in an isolated root.
- [x] Filesystem-neutral **offline staging** implementation with independent APK world databases and persistent data directories.
- [ ] Verify ext4 and XFS staging in GitHub Actions on fresh disposable loop disks.
- [ ] Production-quality vpkg replacing apk inside installed system, while Live bootstrap remains conventional.
- [ ] Filesystem-neutral installed-system boot coordination, verified kernel and initramfs.
- [ ] Complete QEMU installed ext4 root A → stage B → boot B → rollback A → boot A.
- [ ] Equivalent compatibility coverage of XFS, F2FS and Btrfs without making any mandatory.
- [ ] Authenticated full-system metadata, unattended recovery and physical hardware tests.

## Prototype entrypoints

`scripts/veyra-deployment.sh init MOUNT` initializes a separate **persistent** test mount, `verify MOUNT ID` validates a staged OS tree and `stage MOUNT SOURCE-ID NEW-ID` makes a filesystem-independent `rsync` copy of a quiescent previous deployment. The store marker is `VEYRA-DEPLOYMENT-STORE-v2`, deliberately incompatible with the previous Btrfs-only prototype store; **there is no implicit migration**. No stage operation modifies GRUB, active root, partition tables, fstab, EFI variables or installed-system package state.

`tests/test-deployment-fs-neutral.sh` exercises staging, independent world files, persistent data and rejection of invalid deployment IDs on freshly created disposable ext4 and XFS loop filesystems. The older Btrfs-specific snapshot design is **abandoned** as the Veyra deployment architecture.

**Current Calamares and TUI installers remain conventional and filesystem-selectable.** They must keep working until the filesystem-neutral atomic design has passed complete QEMU boot, rollback and power-loss tests.
