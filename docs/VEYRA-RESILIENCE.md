# Veyra Resilience — Guardian and one Recovery Engine for two environments

**Status (2026-10-20): ARCHITECTURE/UX PROPOSAL ONLY.** Guardian, shared Recovery Engine, SnapCore snapshots, online restore and dual-scope VRE menu are **not implemented**. [Stage 1 QEMU manager](STAGE1-USER-ROOTFS.md) and [independent console VRE](VEYRA-RECOVERY.md) are separate prior proofs, not this finished product. See [SnapCore](VEYRA-SNAPCORE.md), [Roadmap](ROADMAP.md).

## Principle: recovery survives the broken thing

If the user destroys `/usr` inside the isolated user environment, `plasmashell`, KRunner and even that environment's OpenRC may fail. **Neither failure detection nor the recovery UI may live in the user rootfs.**

- **Veyra Guardian:** an **initial-namespace, system-OpenRC-owned** health monitor and incident coordinator started before user login. It observes the trusted user-environment manager, process/session state and storage health; it never depends on user `/usr`, user `/home`, user session D-Bus or user `plasmashell`.
- **Veyra Recovery Engine:** a common, narrowly authorized, durable **repair transaction protocol/backend** shared by online system-side Guardian and independent offline VRE. It coordinates **SnapCore user-volume restore** and **system A/B generation rollback** without combining or granting their privilege scopes.
- **Online Repair:** when the system is healthy, diagnose/restart failed user components or stop/unmount user rootfs and restore a verified user snapshot **without reboot**, *only when safety conditions permit*.
- **Veyra Recovery Environment (VRE):** separately booted **kernel + initramfs** running instead of the installed system. It repairs **both user and system environments** even if the installed system, compositor and user processes cannot start. It must contain its own compatible Recovery Engine/SnapCore reader, text UI and filesystem drivers.

System A/B recovery is not dependent on SnapCore, and system rollback never silently changes user rootfs, personal files or snapshot catalogs. This continues the [dual-environment architecture](DUAL-ENVIRONMENT.md).

## Detect the right problem

Use at least **three independent health channels**:
1. **Nested user PID 1 and service lifecycle:** monitored via the trusted system manager, `pidfd` and user OpenRC readiness/error state.
2. **Desktop health:** process exit/health of user-side `plasmashell`, KRunner and private user session bus; bounded, non-destructive restart attempts.
3. **Session heartbeat and functional probes:** short, authenticated, bounded updates; avoid treating a suspended, idle or temporarily frozen GUI as confirmed filesystem corruption.

Combine these with filesystem/SnapCore read-only state, integrity/capacity/IO errors and exact executable availability. Debounce transient failures, rate-limit restarts, distinguish signal sources and record structured diagnostics. **One missing heartbeat or a single `plasmashell` crash must not trigger a snapshot rollback.**

| Symptom | Interpretation | Safe response |
| --- | --- | --- |
| Only `plasmashell` exits; user PID 1/session alive | Shell crash | Restart shell within bounded budget; notify only if persistent |
| Session heartbeat missing; PID 1 alive | Unresponsive/unknown | Probe with timeouts; don't label rootfs corrupt without evidence |
| User PID 1 dies or needed files vanish | User-environment unavailable | Isolate, retain logs, offer retry, diagnosis, verified rootfs restore |
| Snapshot inventory/I/O is corrupted | Storage integrity unknown | Don't claim snapshots are usable; avoid destructive writes, open offline VRE |
| KWin/compositor cannot display UI | Graphical failure | **Independent system TTY**; if system also fails, VRE |
| Installed system generation fails | System A/B or boot fault | Trial-boot fallback if proven; VRE offers generation/boot repair |
| Both environments fail | Dual fault | Offline VRE: restore system, then optionally user volume, never auto-erase data |

## What the user sees

Primary, calm message:

> **Рабочее окружение недоступно.**
> Veyra обнаружила проблему пользовательской среды. Основная система продолжает работать.
>
> **[Восстановить рабочую среду]** **[Повторить запуск]** **[Диагностика]**
>
> Дополнительно: выбрать точку восстановления · открыть автономный Recovery.

This is **example copy, not an implemented UI**. Display system/user/snapshot status **only after verification**, never a falsely reassuring green “snapshot available”. Offer human-readable consequence estimates before write operations; don't use frightening crash art or hide failures behind a generic login error.

### Display-layer fallback

1. **Graphics alive:** run a **system-owned trusted recovery surface** through a securely authenticated system compositor/display path. Because Veyra's KWin is system-owned and user `plasmashell` is not, the compositor may remain usable. **This is a design requirement, not a guarantee**: the overlay must not use user session D-Bus, KRunner, user Plasma runtime or damaged files. Validate anti-spoofing, input/focus rights and authorization.
2. **Graphics gone / KWin dead:** a system-level **TTY text recovery screen** supplied by system OpenRC and independent of user KDE. Provide keyboard-accessible diagnostic output and a controlled reboot-to-VRE option.
3. **System also unbootable:** manual GRUB **Veyra Recovery** entry boots its own kernel/initramfs. Automatic handoff is optional and requires tested boot state and failure handling.
4. **Recovery components corrupted:** explain that local recovery is unavailable and provide externally bootable installation/recovery media guidance. Never promise recovery after full physical disk loss or key loss.

## Shared recovery transaction model

`NORMAL → SHELL_FAILED → LIMITED_RESTART → NORMAL
                             └→ USER_ENV_UNAVAILABLE
USER_ENV_UNAVAILABLE → DIAGNOSE → USER_CONFIRMATION
                     → STOP/QUIESCE USER PID1 → FLUSH/UNMOUNT
                     → VERIFY SNAPSHOT → PRESERVE DAMAGED HEAD (IF POSSIBLE)
                     → ATOMIC RESTORE TO NEW HEAD → VERIFY → START USER
                     → NORMAL or FAIL-SAFE / OFFLINE VRE
SYSTEM_FAILURE → VERIFIED A/B FALLBACK or OFFLINE VRE
SYSTEM + USER FAILURE → OFFLINE VRE: SYSTEM REPAIR, THEN USER REPAIR`

The backend is shared by Guardian and VRE; the two have different execution contexts but one durable transaction format. All writes require explicit user authorization and a clear list of affected **volumes** or **system generations**. Must be crash-recoverable and idempotent (journaled transitions; replay only committed state).

**No online rollback of a mounted writable user rootfs**. Stop all user processes and prove exclusive access; otherwise decline online repair and offer VRE. Verify snapshot health and capacity before the transaction. Attempt a non-destructive pre-restore checkpoint of the damaged state when possible; if impossible, explicitly disclose before proceeding. Never implicitly roll back newer `/home` files: make user OS and personal data separately restorable block-volume domains. Full user-state rollback requires a separate, informed confirmation.

## Trust boundaries

- User `sudo` stays user-namespace root; it must not reach Guardian privileged API, system A/B updates, raw host block devices, SnapCore catalog/store, system OpenRC, bootloader controls, or VRE boot metadata.
- A small audited Recovery Engine broker authenticates the initial-namespace requester. Presentation UI does **not** run arbitrary root commands; use typed operations with volume IDs, snapshot/generation identifiers and explicit authorization.
- Pin/validate filesystem paths, mounts, storage identity, opened metadata and file descriptors. Make failures and missing capabilities **fail closed**. Bound processing times and resource use; log safely.
- Protect independent recovery kernel/initramfs, authenticated artifacts, SnapCore metadata and last-known-good system generation. Treat the physical disk and optional secure boot/TPM separately; these are not already implemented.
- A local snapshot isn't an off-device backup. Corruption of physical storage or total encryption-key loss requires an independent backup/recovery medium.

## Test plan / acceptance gates — ALL OPEN

- [ ] Implement Guardian as an independent system OpenRC service receiving structured health events from the privileged user-environment manager, with restart debounce, heartbeat and error classification.
- [ ] Test shell-only crash vs user PID 1 death vs missing executable vs user session hang: never equate one shell crash to irreparable user-root damage.
- [ ] Build system-owned **TTY recovery interface** independent of user rootfs/D-Bus/Plasma; log and provide a safe path to offline VRE.
- [ ] Prototype system compositor/trusted Wayland Guardian UI, with authenticated input/focus, clear status and no dependency on the broken user shell; test KWin failure fallback.
- [ ] Specify a **single typed Recovery Engine API** and durable transaction journal for both online Guardian and offline VRE, with explicit authorization.
- [ ] Integrate SnapCore snapshot inventory with **verification**, timestamp/affected-volumes display, capacity check, retention and non-destructive checkpoint policy.
- [ ] Implement safe online **user-root-only** restore: stop, quiesce, unmount, verify, checkpoint, restore, verify, restart; preserve newer independent `/home` data.
- [ ] Expose **user snapshot restore** and **system A/B rollback/boot repair** through one independent VRE text menu. VRE must work without installed user/system binaries.
- [ ] Run disposable QEMU destruction test: inner `sudo` destroys the user `/usr` test volume; user Plasma would fail, yet trusted Guardian/TTY remains usable, user root is restored and system kernel/OpenRC stay healthy.
- [ ] Run a second QEMU test proving a newer `/home` document survives user-root restore and a deliberate full-data restore asks for separate consent.
- [ ] Run system-generation breakage and dual-environment failure tests; demonstrate VRE repairs both independently, including no working KWin/TTY in installed system.
- [ ] Fault-inject corrupt/missing SnapCore catalog, ENOSPC, missing key, power cuts during restore, incompatible recovery versions, dead storage and unavailable UI; prove last known-good points are not overwritten.
- [ ] Include keyboard accessibility, progress based on actual transactions, accurate error messages, diagnostic logs, and clear destructive-action confirmations.
- [ ] Independent security review before installation/default enablement. All tests above must be evidenced by passing reproducible CI and QEMU runs.

**No Guardian, SnapCore online restore or unified dual-environment VRE repair UI exists in released/installed Veyra as of this design record.**
