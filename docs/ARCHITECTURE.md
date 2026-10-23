# Veyra Linux architecture — decision record (2026-10-19)

**Status: approved direction; incremental implementation. Not a claim that the current ISO or installed system is atomic.**

The installed target also has **two concurrent, isolated Linux environments** on one kernel: a privileged system environment and a persistent independently managed user environment. See [Dual Environment](DUAL-ENVIRONMENT.md) and [Development Roadmap](ROADMAP.md). The Live-vs-installed distinction below is separate from that runtime design.

## Live versus installed Veyra (distinct from the two runtime environments)

1. **Veyra Live ISO** is a conventional, Alpine 3.22/musl/OpenRC, RAM-backed live environment with KDE Plasma, networking, Calamares, diagnostic tools and the Alpine APK bootstrap. It is **not an A/B system**. This makes the installer and rescue environment simple and keeps the existing QEMU ISO boot and installation path working.
2. **Installed Veyra Plasma edition** is the target for an **atomic, versioned OS**, where the kernel, initramfs, OpenRC services, Qt/KDE Frameworks, KWin, Plasma, portals, host PipeWire and native Mesa belong to one coherent **system deployment**. Plasma is installed from packages, but its *versions* are managed as part of the host deployment, not freely replaced in the running root.
3. **User data and applications** are outside the rollback boundary. `/home`, user Nix profiles and durable application state must survive switching between system deployments. Each deployment needs its own APK database and package world. A shared `/var/lib/apk` database would be incorrect.
4. **glenv** stays distinct from the host musl/KDE desktop: a shared, signed Debian glibc runtime is paired to each Veyra host deployment and mounted read-only for host and user environments. No glibc libraries replace the native musl system or KWin.
5. **KDE-only target:** installed Veyra has one system-owned, coherent KDE Plasma platform. Its `plasmashell` and KRunner processes run in the isolated user environment from a version-paired read-only system KDE runtime. Other desktop packages installed in the user environment do not replace Veyra's system desktop. The current interim installer also installs Plasma only, but this does not establish the final dual-environment architecture or a version-paired KDE runtime.

## Package manager

`vpkg` becomes Veyra's user-facing package manager, derived from and crediting upstream `apk-tools` (GPL-2.0-only). It must keep Alpine package format, signatures and dependency solver compatibility, including the trusted Veyra APK repository. Maintain the appropriate GPL-2.0-only source/patches and copyright notices.

* Initial development and **Live ISO bootstrap** keep genuine Alpine `apk` available until the replacement is feature-complete. Alpine base, mkinitfs, abuild and mkimage depend on it; deleting it now would break the installer.
* Prototype `vpkg-engine` builds directly from a **pinned apk-tools 2.14.x source** with explicit downstream changes, under a distinct binary name. It runs only in test/build environments until audits pass. This is not a finished forked system package.
* `vpkg` is for the persistent user environment only. For a requested package, its intended source order is Alpine APK repositories, then the signed `veyra-pkgrepo` APK repository, then Nix if neither APK source has the package. Both APK sources use the APK format. The Veyra repository contains both system and user packages, but repository membership does not give `vpkg` permission to modify the system environment.
* System package installation is a separate administrative operation: after the future password-gated system-shell bridge is entered, use the system environment's ordinary `apk` tooling. System updates remain staged as host-authorized A/B transactions.

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

The filesystem-neutral prototype includes a GRUB boot-config selector and an opt-in initramfs root-directory selector. A local disposable ext4 QEMU run of `tests/test-atomic-qemu.py` passed the system-only sequence A → confirmed B → failed trial C → automatic fallback to B → explicit rollback to A. Its user roots were synthetic fixtures; this is not a signed paired update or production recovery guarantee. Full atomicity still requires durable staging and verification, authenticated kernel/initramfs/boot entries, recovery from power loss and other failure modes, and a validated system/user fallback pair. A simple directory rename alone is **not sufficient** to claim atomic boot, and a read-only mount alone does not prevent privileged changes to the underlying source.

The installer must permit users to keep choosing ext4, Btrfs, XFS or F2FS. It must not reformat, force Btrfs, or silently migrate an existing filesystem. The system-only ext4 QEMU prototype cycle now has local evidence; a signed installed system/user A/B cycle and failure coverage are still required before production activation. Other supported filesystems need compatibility coverage too.

## Implementation gates

- [x] Non-atomic Live ISO and QEMU console installation into a disposable disk.
- [x] Experimental signed glenv per-host release pairing and read-only mounts.
- [x] Native apk-tools-derived vpkg engine prototype, tested in an isolated root.
- [x] Filesystem-neutral **offline staging** implementation with independent APK world databases and persistent data directories.
- [x] Verify ext4 and XFS staging and A/B GRUB config activation in GitHub Actions on fresh disposable loop disks.
- [ ] Integrate `vpkg` into the persistent user environment with Alpine → Veyra APK → Nix fallback resolution; keep the system environment on ordinary `apk` behind the protected system-shell bridge.
- [x] Experimental filesystem-neutral GRUB selection and actual early-root bind mounts; validated on ext4 in isolated Linux namespace.
- [ ] Full production boot metadata authentication and verified kernel/initramfs provenance.
- [x] System-only disposable ext4 QEMU A → confirmed B → failed trial C → fallback B → explicit rollback A prototype; user-root fixture is synthetic.
- [ ] Complete a signed paired system/user update and rollback on an installed ext4 system.
- [ ] Equivalent compatibility coverage of XFS, F2FS and Btrfs without making any mandatory.
- [ ] Authenticated full-system metadata, unattended recovery and physical hardware tests.

## Prototype entrypoints

`scripts/veyra-deployment.sh init MOUNT` initializes a separate **persistent** test mount, `verify MOUNT ID` validates a staged OS tree and `stage MOUNT SOURCE-ID NEW-ID` makes a filesystem-independent `rsync` copy of a quiescent previous deployment. The store marker is `VEYRA-DEPLOYMENT-STORE-v2`, deliberately incompatible with the previous Btrfs-only prototype store; **there is no implicit migration**. No stage operation modifies GRUB, active root, partition tables, fstab, EFI variables or installed-system package state.

`tests/test-deployment-fs-neutral.sh` exercises staging, independent world files, persistent data and rejection of invalid deployment IDs on freshly created disposable ext4 and XFS loop filesystems. The older Btrfs-specific snapshot design is **abandoned** as the Veyra deployment architecture.

**Current Calamares and TUI installers remain conventional and filesystem-selectable.** They must keep working until the filesystem-neutral atomic design has passed complete QEMU boot, rollback and power-loss tests.

## Experimental boot coordinator and QEMU gates

The bootloader now loads a kernel and initramfs from the selected directory, for example `/deployments/A/boot/`, on the **user-selected filesystem**. The kernel command line contains `root=UUID=<STORE-UUID> rootfstype=<USER-FS> rootflags=rw veyra_deployment=A`. Veyra injects a validated `veyra_deployment` parser and early-root selector into a **copy** of Alpine's packaged init script via `scripts/build-veyra-init.sh`. It does not overwrite Alpine's `mkinitfs` installation. Before OpenRC starts, the initramfs mounts the selected system tree at `/`, along with independent persistent `/home`, `/nix` and shared data. This mechanism uses Linux bind mounts and ordinary directories; **no snapshots, subvolumes or CoW operations are involved**.

`scripts/veyra-bootctl.py --store STORE init --uuid UUID --fstype ext4 --default A` generates a GRUB config in the *outer* `STORE/boot/grub/` directory. `activate ID` and `rollback ID` only replace a verified config via same-directory atomic rename and fsync. A boot coordinator can adopt and back up a conventional GRUB config with the **explicit** `--adopt-legacy-grub` option, retaining a menu entry for the original Alpine installation as manual recovery. GRUB/kernel/EFI signatures and unattended watchdog fallback are **not yet guaranteed**.

`scripts/veyra-atomic-convert.sh` is an **opt-in, disposable-VM-only** conversion helper for an already installed, offline conventional Alpine root. It duplicates the OS into deployment A, copies persistent data separately, builds A's own initramfs and configures the GRUB entry. The original root remains as a legacy recovery option. It has **not** been enabled as the default Calamares or TUI installation path. The experimental `tests/test-atomic-qemu.py` and `.github/workflows/atomic-e2e.yml` cover QEMU boot A, confirmed B, failed trial C with fallback to B, and explicit rollback to A on a temporary ext4 qcow2 disk. User-root fixtures are synthetic. This does not establish signed paired updates, power-loss atomicity, secure boot, production unattended recovery or hardware support.

`vpkg` exposes package operations only. Boot selection remains a separate system-side `veyra-bootctl` operation and is not part of the user package manager. System package changes belong to the protected system shell and ordinary system `apk`, or to the trusted inactive-generation updater.

**Filesystem commitment:** ext4, XFS, F2FS and Btrfs remain choices of the end user. The root design must not depend on any particular filesystem's snapshot, reflink or rename extensions. All existing conventional installations remain usable until explicit migration is tested and supported.

## Pre-Alpha paired updates and user data

Veyra Linux Pre-Alpha is first qualified on **x86_64 + ext4 in QEMU**. Its update contract is:

1. Keep the system deployment and the shared user-environment root as independently versioned roots. The system root owns the kernel, host services and boot policy; the user root owns its own OpenRC/PID 1, package database and ordinary applications. Both roots share the running kernel.
2. Deliver one signed release description that names the compatible system package set, user-environment package set and their compatibility IDs. The existing signed `veyra-pkgrepo` index and APK signatures authenticate the packages; release metadata must be authenticated before it can select a pair.
3. Stage updates only into inactive roots. A system-only release can retain the current user root when its compatibility ID allows it. A release that changes both environments stages both and activates the pair together.
4. Keep `/home/LOGIN`, user Nix/Flatpak state and declared persistent application data outside both roots. The update payload never includes these paths. The user package selection is retained as desired state and resolved against signed repository packages when creating the next user root.
5. Treat root-owned configuration and database migrations as versioned update inputs. Apply only declared migrations to staged roots; require backward-compatible persistent state or a verified reversal path before activation. Decline an update when migration safety or space checks fail.
6. After verifying package signatures, manifest compatibility, each root's package database, kernel and initramfs, arm a one-time trial boot of the new pair. Confirm it only after the system and user-environment supervisors report healthy startup. If confirmation does not happen, the next boot selects the last confirmed pair. `/home` remains unchanged in either direction.

This is the **Pre-Alpha target**, not the current implementation. The present `veyra-update` package still runs `apk upgrade` in place; staging and activation are still prototype operations, and there is no complete signed updater or paired system/user fallback. The system-only disposable QEMU prototype has automatic fallback from failed trial C to confirmed B, but its user roots are synthetic. Replace the prototype path before publishing. An integrated system/user A/B QEMU test must prove successful confirmation and a deliberately failed trial boot returning to the prior pair while preserving account data and package selections.

`vpkg` presents one package-manager interface over APK and Nix, always operating in the user environment. It refuses to invoke either backend unless `/run/veyra/user-environment` contains `user-v1`; this marker is an accidental-misuse guard, while the user namespace and mount layout provide the actual isolation. Its default install path checks configured untagged Alpine APK repositories first, then the signed `@veyra` APK repository, then Nix only when the package is absent from both APK sources. The Veyra repository contains both system and user packages; repository membership never lets `vpkg` modify the system environment. The Nix backend wraps imperative `nix profile` operations for the current user's profile. The CLI implements ordered source lookup, but production user-root integration and end-to-end validation remain incomplete. `--from apk|nix` selects a specific backend. The current installer does not create the marker, so `vpkg` fails closed on the installed development system.
