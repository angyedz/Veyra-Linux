# Veyra Recovery Environment (VRE) — design v0

Status: **independent Alpine LTS recovery kernel + initramfs successfully boot-tested in diskless QEMU** (`scripts/veyra-recovery-init.sh`, `scripts/build-veyra-recovery.sh`, `tests/test-recovery-qemu.py`, `.github/workflows/recovery-e2e.yml`). Serial diagnostics work. This is not yet integrated into GRUB or security reviewed; no graphical UI or automated update application exists.

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
