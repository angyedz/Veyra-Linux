# Veyra Recovery Environment (VRE) — design v0

Status: **independent Alpine LTS recovery kernel + initramfs successfully boot-tested in diskless QEMU** (`scripts/veyra-recovery-init.sh`, `scripts/build-veyra-recovery.sh`, `tests/test-recovery-qemu.py`, `.github/workflows/recovery-e2e.yml`). Serial diagnostics work. This is not yet integrated into GRUB or security reviewed; no graphical UI or automated update application exists.

## Expert Recovery Shell

The independent, diskless Recovery initramfs now has an **expert-only
interactive BusyBox shell**. The user must type `SHELL` at the warning;
entering an arbitrary response cancels the operation. The shell is a child
of Recovery's PID 1, so `exit` returns to the main recovery menu instead
of ending init. BusyBox commands are available without using binaries from
the installed root. No installed root or data volume is mounted on entry.

**Warning:** Recovery is privileged. Commands typed inside this expert
shell can modify disks. This feature is not an automated repair path.
Diskless QEMU tests cover cancellation, shell command execution and return
to the main menu. An installed boot-menu entry and device qualification
remain separate unverified gates.

## Android-inspired design, not an Android port

Borrow the **A/B boot state machine**, **post-install verification**, **boot-success acknowledgement** and a **minimal recovery interface**, rather than importing Android's block-level update_engine or partition assumptions. Veyra generations are directory trees on a user-selected Linux filesystem, **not mandatory A/B partitions**. Btrfs, snapshots, reflinks and LVM must never be required.

Reference: https://source.android.com/docs/core/ota/ab

## Separate boot target

- GRUB retains conventional and generation entries, plus **Veyra Recovery**.
- Recovery has its own versioned, verified kernel and initramfs; it does not depend on KDE, the selected generation's root, or /home.
- The initramfs contains BusyBox, filesystem drivers for the user's selected filesystem, read-only diagnostics, and a small framebuffer/DRM UI. Start with serial/text mode; graphical progress is a later, separately tested feature.
- Recovery never formats disks or changes partition layout automatically. Mount the store read-only until an explicitly authorized repair/update requires writes.
- Reserve a recovery artifact location independent of deployment trees. Prefer a versioned /boot/veyra-recovery/ artifact directory on the existing boot filesystem, with safe fallback to a previously verified image. Do not presume a separate EFI System Partition or /boot.

## Transaction states

1. RUNNING_A: system A is active and confirmed.
2. PREPARING_B: update daemon constructs inactive generation B, while A continues running. No modifications to A, shared user data or GRUB default.
3. VERIFYING_B: check signed manifest, hashes, APK world/database, kernel, initramfs and free space; run safe post-install checks.
4. READY_B: sync and durably record prepared metadata, including a fallback to A.
5. TRIAL_BOOT_B: set a limited boot attempt for B; preserve A as the confirmed fallback.
6. CONFIRMED_B: OpenRC checks that the actual B root and essential services started, then records boot success.
7. FALLBACK_A: after failed attempts, select A automatically, log reason and expose Recovery.

No GRUB-only graphical animation should be mistaken for actual progress. VRE shows percentages only when operations report measurable work; otherwise use indeterminate progress and stage labels.

## VRE user experience

- Use the canonical repository asset `branding/veyra-logo.svg` as the Veyra logo (convert it to a supported boot/recovery bitmap format during the build); minimal accessible text + progress. Do not substitute a snowflake or invent another symbol.
- Modes: "Applying offline update", "Verifying system", "Rolling back", "Repairing boot", "Diagnostics".
- Esc: show detailed log, generation selection and recovery options.
- On failure: keep the last confirmed generation bootable; show a concrete error and write durable logs to persistent/shared (only after checking mount integrity).
- Never touch /home or /nix in a rollback. Data migration must be independently reversible or explicitly disclosed as not reversible.

## Trust and resilience boundaries

- Verify signatures and rollback metadata before executing any downloaded update scripts.
- Never run scripts from an unverified payload.
- Power-loss-safe, fsync-backed state transitions and generation promotion; prevent concurrent writers.
- Boot-attempt counting needs an independently durable GRUB-compatible state mechanism; a service running only after successful boot cannot detect a kernel hang. Do not call automatic rollback complete until a forced-failure QEMU test proves it.
- Preserve a manual recovery entry even if boot metadata is damaged.
- Support ext4, XFS, F2FS and optionally Btrfs, subject to tested kernel modules and bootloader support.
- Secure Boot and TPM integration are separate work items, not implicitly provided by GRUB.

## Implementation sequence

1. Make existing QEMU A -> B -> A pass with real Alpine (still pending confirmation).
2. Add read-only VRE boot artifact, serial-mode diagnostics, and a manual GRUB entry; test independent boot.
3. Implement verified transaction metadata and limited trial boots with forced-failure QEMU coverage.
4. Add update worker for inactive generation and signed manifest verification.
5. Add framebuffer/DRM progress UI backed by real operation events.
6. Add recovery repair flows and destructive-action confirmations.
7. Test power interruption at every state transition and each supported filesystem.

**Non-goal:** replacing GRUB with a new bootloader immediately. "Veyra Boot" is the branded boot experience; GRUB remains its tested underlying bootloader.


## Veyra Resilience: one Recovery Engine for system and user repair (new design, 2026-10-20)

See [Resilience/Guardian architecture](VEYRA-RESILIENCE.md), [SnapCore design](VEYRA-SNAPCORE.md), and [Roadmap](ROADMAP.md). **None of the following user-facing rescue flows are implemented yet.** The present VRE milestone is an independent console kernel/initramfs boot in diskless QEMU, **not** an installed dual-environment recovery utility.

VRE must provide **two independent restoration scopes in the same text-first interface**:
1. **System:** validate boot/generation state, choose the last verified A/B generation, repair boot and retry. This path is separate from SnapCore and never implicitly rewinds user root, personal files or snapshot metadata.
2. **User:** validate available SnapCore snapshots and damage, stop/mount exclusively or operate offline, choose a user-root snapshot and restore into a new writable head while retaining a separate newer `/home` volume. Full personal-data rollback requires separately listed volumes and explicit informed confirmation.

**The same Recovery Engine** supplies typed, authorized, crash-consistent transactions to VRE and to **online system-side Guardian** where online unmount/repair can be proven safe. VRE must carry its own compatible SnapCore reader/backend, not use software in a damaged installed rootfs, and refuse mutation if its storage format is unsupported, catalog invalid or mount exclusivity cannot be guaranteed.

### Independent failure notification and safe UI

- System Guardian must detect nested PID 1 failure and independently observe `plasmashell`/session health; a single shell crash triggers bounded restart, **not** whole-volume rollback.
- When user environment is missing, the **system-side** graphics surface (if KWin remains healthy) shows a calm “Рабочее окружение недоступно”; it cannot depend on user KDE, `/usr`, user D-Bus or `/home`. Its trusted input path needs review. **Always provide system TTY fallback**, then offline VRE when system graphics or boot cannot run.
- Expose only **verified** snapshot/generation choices and real repair stages. Preserve the damaged user-state head as a checkpoint if possible, explain any loss if impossible, and get confirmation **before** destructive writes.
- VRE must remain bootable when both installed environments fail; do not assume local snapshots survive physical disk failure. Provide external backup/recovery-media guidance.

### Required validation (all pending)

- [ ] Common Recovery Engine durable format/API for both online and offline repair; explicit system vs user privilege scopes and operation confirmation.
- [ ] Guardian OpenRC service and independent TTY UX with bounded desktop-restart, user-init-crash and storage-failure detection.
- [ ] Offline VRE menu that restores **user SnapCore** and **system A/B** without either installed environment or Plasma.
- [ ] QEMU: delete files inside a **disposable** user-root under inner `sudo`, verify Guardian notification, restore user root while preserving newer personal data; force separate system damage and dual damage with VRE repair.
- [ ] Simulated power interruption, missing snapshots, ENOSPC, wrong keys, failed compositor and incompatible SnapCore catalog; no loss of the last verified rescue point.
