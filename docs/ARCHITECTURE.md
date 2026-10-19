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

## Intended Btrfs system layout (not yet installed by Calamares)

```text
Btrfs top-level (subvolid=5)
  @system-A       # one self-contained Alpine+KDE root, /etc and APK database
  @system-B       # another independent root, kernel and initramfs
  @home           # persistent /home, not rolled back by OS updates
  @nix            # optional persistent /nix
  @shared         # tightly scoped persistent state (not a shared APK database)
  @boot           # stable, bootloader-owned configurations
ESP               # independent EFI system partition on UEFI machines
```

At most one selected deployment is booted as `/`. An inactive deployment is staged and checked before selecting it for the next boot; the previous system remains available for rollback. **Both boot entries must be recoverable**, including after power loss. A/B root subvolumes, bootloader selection and signature metadata must be authenticated together, not merely renamed in userspace. A read-only snapshot is insufficient if a privileged process can still modify its Btrfs source or boot metadata.

A production installer must verify UEFI and BIOS partition schemes, Btrfs mount semantics, stable rootflags, fstab, kernel/initramfs resolution, filesystem durability, ESP and GRUB updates, power-loss recovery, state migrations, disk space, encryption, and rollback to a *boot-tested* root. Do **not** enable this layout on real machines until a full QEMU disk-install → reboot A → stage B → boot B → rollback A test passes.

## Implementation gates

- [x] Non-atomic Live ISO build and QEMU console installation on disposable disk.
- [x] Experimental glenv signed per-host release pairing and read-only bind tests.
- [ ] Independent, tested native `vpkg` APK-derived engine.
- [ ] Versioned deployment metadata, safe inactive-slot preparation and separate APK databases.
- [ ] Calamares **atomic Plasma edition** installer path and verified Btrfs boot layout.
- [ ] Tested GRUB A/B selection, fallback and power-loss-safe commits.
- [ ] Persistent user data across A/B and rollback with signed glenv host binding.
- [ ] Signed full-system release policy, authenticated boot metadata and hardware tests.

Until those gates pass, the existing installed system remains the conventional Alpine install. This document is a target contract, not evidence that unfinished components work.
