# Veyra SnapCore — protected block-level snapshots of the user environment

**Status (2026-10-21): experimental file-backed engine prototype v0.2 in review.** The Python prototype and rootless replay tests live in `snapcore/` and `tests/test_snapcore.py`. Commit `b21fc70` adds four fixed-seed reference-model histories with pruning, GC and reopen; all 26 tests pass locally as an unprivileged user, in [dedicated SnapCore CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39509850855) and in [full integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39509850737). It remains disconnected from boot, user storage, VRE and Guardian and is not production-ready. Related: [Veyra Resilience](VEYRA-RESILIENCE.md), [VRE](VEYRA-RECOVERY.md), [Roadmap](ROADMAP.md).

## Decision and objectives

Veyra should have a **Veyra-owned copy-on-write (CoW) block-volume snapshot engine** that does **not** depend on Btrfs subvolumes, reflinks, directory-tree copies, or mandatory LVM snapshots. A snapshot records an immutable version of a *logical block mapping*; new writes to the active volume allocate new extents while still-referenced old extents remain available. Snapshot creation is primarily metadata work, **not** duplication of `/usr`, `/etc` or `/home` into other folders. Storage consumption grows with changed blocks, metadata and fragmentation; no promise of zero overhead, compression, unlimited snapshots, or instantaneous full-volume verification.

The engine sits **below an ordinary filesystem**. Test ext4 first, then XFS, F2FS and optionally Btrfs used as an ordinary filesystem. Do not claim compatibility without independent filesystem-specific tests. **System A/B** remains the pre-existing filesystem-neutral, directory-generation mechanism and must work without SnapCore, block CoW or snapshots.

The storage service and controller belong to the **system environment**, not the user's own root (inner `sudo`). Its metadata and backing device must not be accessible via guest device nodes, writable mounts, inherited FDs, control sockets, host D-Bus or raw storage operations.

## Experimental file-backed prototype v0.2

The implementation in `snapcore/engine.py` uses a private test directory instead of a real block device:

- Each logical block is an immutable, SHA-256-named extent file. Partial writes read the previous block and publish a replacement extent; sparse zero blocks have no extent.
- Each logical map is an immutable, content-addressed root. Generations refer to roots, so writes do not mutate extents or roots reachable from earlier generations.
- Checkpoints append a journal event that pins the current generation. Rollback appends a new generation referencing the checkpoint root; it does not rewrite or remove later generations.
- Normal journal events use a checksum chain, monotonically increasing sequence, data/root-before-journal ordering and `fsync` boundaries. A trailing incomplete record is discarded on open; a complete record with a bad checksum fails closed. Pruning replaces the journal with a compacted base as described below.
- If an error occurs after opening the journal for an append, the current handle is marked unusable because the commit may or may not be durable. It refuses further reads of state and writes until closed and reopened; replay then selects the valid prior or fully appended generation. Injected I/O errors cover partial append, complete append before `fsync`, and after `fsync`; these are storage-fault simulations, not physical power-loss tests.
- `prune --keep-last N` verifies the full current history, retains the active head, the latest N generations and every named checkpoint, then atomically replaces the journal with one bounded compacted-base record. A generation whose parent was pruned becomes a new retained-history boundary. The format-v2 parser validates every retained map and checkpoint reference; startup removes only recognized leftover compaction temporary files.
- Pruning is refused unless at least one named checkpoint exists. Deleting a checkpoint is refused when it would remove the last named recovery point; any remaining checkpoint must pass full extent verification. The count budget and one-megabyte compacted-record limit can still prevent pruning an unusually large retained set.
- `verify()` checks every retained map and referenced extent. Snapshot inventory can request the same verification before a point is offered.
- Checkpoint creation and rollback publication verify all extents in the selected map first. A corrupt current head cannot be blessed as a checkpoint, and a corrupt snapshot cannot become the active head.
- Deleting a checkpoint is a journaled operation. `gc` verifies every retained generation before removing only unreferenced content objects or abandoned temporary files. After pruning compacts the journal, maps and extents reachable only from pruned generations become reclaimable.
- The developer CLI is `scripts/veyra-snapcore.py` (`format`, `write`, `read`, `snapshot`, `delete-snapshot`, `rollback`, `prune`, `verify`, `status`, and `gc`). Format v2 has no migration path from the earlier prototype format. This prototype still has no block-device interface, filesystem freeze/thaw, filesystem-consistency guarantee, encryption, authenticated metadata, dual-superblock recovery or VRE reader. Checksums detect accidental corruption; they do not authenticate the store against a privileged attacker.

The crash tests terminate a writer process at deterministic persistence boundaries and reopen the store. They test journal replay and incomplete-tail recovery, **not** physical power loss, device-cache behavior, kernel `ublk` semantics or filesystem recovery. No real ext4/XFS/F2FS volume is mounted on this prototype.

## Logical architecture

`SYSTEM OPENRC / TRUSTED SNAPCORE SERVICE
    ├── snapshot catalog + generation maps + protected physical extent store
    ├── durable transactions / recovery metadata
    └── narrowly authorized virtual block device (candidate: Linux ublk)
          └── ext4 / XFS / F2FS (filesystem compatibility tested separately)
                └── persistent user-root logical volume
                    └── user PID 1 / OpenRC / applications / inner sudo

INDEPENDENT VRE (separate kernel + initramfs)
    └── compatible SnapCore recovery reader/engine and A/B recovery engine`

`ublk` is a *candidate*, not a committed production dependency; evaluate kernel versions, failure semantics, I/O flush/ordering, security and Recovery availability. The SnapCore service must be started **before** the user rootfs is mounted, and VRE must be able to open the on-disk format without loading any binaries from a broken installed user environment.

### Snapshot representation

- The active logical volume has a writable *head mapping* from logical block numbers to physical extents in a protected store.
- Snapshot `S1` references a durable immutable mapping root, volume identity, creation sequence and consistency metadata. Unmodified extents are shared **by reference**.
- A later overwrite writes to a new extent and commits an updated active map. Data reachable through `S1` must remain unchanged.
- Historical snapshots are **read-only**. Rollback selects a snapshot into a **new writable head**, never edits the snapshot or silently destroys later checkpoints.
- Delete/prune reclaims only extents no longer reachable from any active head, rollback checkpoint or retained snapshot. Define quotas, reserve metadata space, reference counting/reachability, safe garbage collection and last-known-good retention before release.
- Test-only first implementation may use a file-backed append-only extent store and a CoW map tree; choose the actual tree/segment structure after measurement and crash-safety review.

A block snapshot is not a filesystem copy, but it is also **not an off-disk backup**. Physical drive loss, lost keys or privileged corruption of the shared store can destroy current data and local snapshots.

## Personal files and snapshot scope

**Critical user promise:** “Restore user environment” must **not silently restore an old version of newer personal files**.

Block CoW snapshots operate on **whole logical volumes**, not arbitrary directories. Therefore decide and provision independently restorable domains, at minimum:
- **User OS/root volume:** `/usr`, `/etc`, user OpenRC, user package database and environment-specific files.
- **Personal files volume:** `/home`, with its own backup/snapshot policy and a deliberately separate restore choice.
- **Other durable state:** user Nix profiles, application data, downloads or package caches may need further explicitly documented domains; do not assume all `/var` is disposable.

An optional separate, carefully audited file-extraction tool may help retrieve documents, but **file copying is not SnapCore's snapshot mechanism**. No automatic migration/rollback of `/home` during system A/B rollback. User rootfs and SnapCore catalogs must remain outside system A/B generations. Define generation/format compatibility for A→B→A and independent VRE.

### Failure mode: deleting `/` can also delete `/home`

**Separate snapshot domains do not protect the *live contents* of mounted personal-data filesystems against inner root.** For example, a destructive recursive removal started at `/` inside the user environment can traverse a writable `/home` mount and delete personal documents even while the system kernel, host root and trusted SnapCore store remain intact. A separate `/home` volume makes its *restore scope* independent; it is not a permission boundary against the owner or inner `sudo`.

- Never advertise **"restore environment, preserve all files"** when the live `/home` contents are damaged or unverified. Say explicitly that reverting the user OS leaves the **current** `/home` as-is; erased current documents require an earlier retained personal-volume snapshot or an independent backup.
- Before intentional full-tree deletion tests, snapshot **both** user OS and the separately mounted personal volume inside **disposable** QEMU/VirtualBox guests. Test an OS-only restore with `/home` unaffected **and separately** test cross-mount deletion plus an explicitly authorized personal-volume restore. Never run the deletion test on a developer's real machine.
- The product may offer separately scoped personal-data snapshots, but user root must not be able to destroy their stored generations or SnapCore metadata. Ordinary file permissions alone cannot provide that guarantee against inner root; enforce it at namespace/device/privileged-service boundaries.

**Two different guarantees must never be conflated:** (1) recovery can roll back the user **OS volume without rewinding newer undamaged `/home` files**; (2) if those newer files themselves were deleted, recovery succeeds only when another **valid snapshot or external backup** still contains them. Neither CoW nor A/B can recover data that was never preserved.

## Consistency, power loss and format contract

Nothing here is implemented yet. Before presenting SnapCore as safe, specify and test:

1. A versioned on-disk volume format with durable generation identifiers, protected mapping roots, checksums, replayable journal/intents, duplicate/rotating superblocks or recovery headers, bounded parsers, and explicit compatibility policy.
2. A clearly defined **atomic commit boundary** for writes, snapshot create/delete and restore; use correct write ordering, barrier/flush/FUA and `fsync` semantics. A power cut must reveal either a fully committed prior state or a valid new state, never a half-published map.
3. Immutable extent preservation under concurrent writes and reclamation, including partial-block writes, discards/TRIM, sparse extents, ENOSPC, crash during garbage collection and catalog damage.
4. At least **filesystem crash consistency**. For a filesystem-consistent checkpoint, quiesce or stop user services and freeze/unmount the filesystem while committing a stable mapping-root; always thaw on timeout/failure, never leave the active user volume frozen after a manager crash. Validate freeze support per filesystem. Application/database-consistent snapshots require extra hooks, not just freeze.
5. Snapshot integrity verification (catalog/mapping/extent reachability, checksums, optional signed metadata where meaningful, filesystem checks) **before** advertising availability. Do not mark a corrupted or missing point as safe.
6. A reserved recovery capacity budget, safe retention, explicit cost/space warning, optional encryption and recoverable key handling, and refusal to overwrite last known-good points when out of space.
7. Fail-closed behavior on store service crash, bad I/O, full disk and incompatible format (e.g. remount active volume read-only, stop workload, offer offline VRE) rather than bypassing CoW.

## Restore transaction and safety requirements

The common [Recovery Engine](VEYRA-RESILIENCE.md) accepts only authorized requests from system-side Guardian or offline VRE.

- Stop and reap user processes; verify no other writable mounts/FDs access the target logical volume; flush and unmount. Never restore a live writable filesystem. If this cannot be proved in the current system, select **offline VRE**.
- Show the selected snapshot and volumes; explain exactly what changes would be lost. Default to user OS/root only, **preserving separate newer `/home` data**. Full user-state rollback requires explicit volume selection and informed confirmation.
- Preserve the damaged pre-restore head as a **separate checkpoint** if space/integrity allow. If this cannot be done, disclose risk and require consent or refuse.
- Verify a candidate snapshot; atomically commit a *new active head* based on it, re-check filesystem state, and only then bring user PID 1 back. Interrupted recovery must resume or roll back to a known good state.
- A system environment failure is repaired by the separate **system A/B rollback path**; SnapCore must not grant inner `sudo` access to host recovery, boot or A/B metadata.
- A healthy local snapshot cannot protect against dead disks or destroyed local keys. Offer/encourage **independent external backup** for these scenarios.

## QEMU implementation and verification tasks

- [x] Initial v0.1 milestone: file-backed immutable block extents and mapping roots; sparse and partial reads/writes; checkpoint preservation; rollback into a new head; and full retained-generation/extent verification. The initial 10-test check was followed by 18 tests on commit `913a3dd`, including CLI, deletion and GC crash cases; [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39491453665) and [dedicated SnapCore CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39491453650) passed. This closes only the simulated-engine milestone.
- [x] Inject child-process termination before immutable extent/root publication, after extent/root sync, in the middle of a multi-block write, during partial journal append, after full append before sync, and after journal sync; retry writes, replay a valid prior or committed generation, and preserve the last-known-good point.
- [ ] Define the production volume/catalog format, complete CoW invariants, bounded parser, atomic journal, error policy, encryption/compatibility strategy and independent recovery reader.
- [x] Add a journaled snapshot-name deletion and reference-aware garbage collection for unreferenced objects; tests retain every generation and snapshot-reachable extent, refuse collection when a live generation is corrupt, recover deletion after process interruption, and restart collection after a crash. All 19 tests pass in dedicated and full integration CI on commit `17a8834` (links above). Generation history remains fully retained.
- [x] Fail closed after uncertain journal I/O: poison the in-memory handle after append/fsync errors, require close and replay before any further state access, and test partial append, complete append and post-fsync failures. All 20 tests pass locally and in [dedicated SnapCore CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39505268065) plus [full integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39505267978) on `45bb114`.
- [x] Define prototype retention policy and safe generation pruning; prove it retains the active head, every named checkpoint and at least one verified recovery point. This does not yet define a production quota or age-based policy.
- [x] Add four fixed-seed reference-model histories that interleave partial/sparse writes, checkpoint creation/deletion, rollback, pruning, GC and reopen; compare the active volume and all retained checkpoint contents after each operation.
- [ ] Broader property/fuzz and concurrent-I/O testing: more seeds, in-process readers/writers, extent reference counts, ENOSPC and last-known-good retention.
- [ ] Test actual power loss or storage fault behavior on supported filesystems and devices; process termination tests do not prove hardware flush semantics.
- [ ] Evaluate Linux `ublk` (or alternative reviewed virtual block interface), its flush/discard and kernel requirements; keep backend and raw device unexposed to user root.
- [ ] Boot disposable QEMU with ext4 formatted on SnapCore; create snapshot; destructively mutate **only the disposable user rootfs**; restore the snapshot without filesystem-tree copy.
- [ ] Test filesystem-consistent checkpoints, freeze/thaw failure recovery, mounted-device safeguards and flush semantics on ext4, XFS, F2FS and optionally Btrfs.
- [ ] Test separate user-root and `/home` volumes: destroy user-root files, restore user OS, and prove a newer personal document remains.
- [ ] Test ENOSPC, metadata corruption, malicious snapshot catalog, invalid keys, damaged current head, backend crash, repeated rollback and interrupted restore.
- [ ] Verify SnapCore can be activated **inside independently booted VRE** with a corrupted installed user/system root, including format compatibility across A/B.
- [ ] Test production space reservation and quota/age-based retention policy; prohibit automatic deletion of the only verified last-known-good snapshot. Prototype pruning/replay tests are complete as listed above.
- [ ] Require adversarial review and repeatable QEMU recovery evidence **before production default enablement**.

**Do not tick these boxes until actual code and reproducible test results exist.**
