# Veyra Linux development roadmap

**Last reviewed:** 2026-10-23

**Status:** engineering plan, not a claim that any unfinished component ships. The first public release target is **Veyra Linux Pre-Alpha**; choose its version and tag only after the release candidate passes its gates. The conventional single-root installer is an internal validation path, not a public release milestone.
**Target:** an installed KDE-only, filesystem-neutral, atomic Veyra with **two independently administered Linux environments on one kernel**, plus separately bootable Recovery.

This plan is ordered by **dependencies and acceptance gates**, not by calendar estimates.
Parallel tracks are intentional; avoid turning prototypes on in the normal boot path until their gates pass. Decisions live in [Architecture](ARCHITECTURE.md), [Dual Environment](DUAL-ENVIRONMENT.md), [Recovery](VEYRA-RECOVERY.md), [SnapCore](VEYRA-SNAPCORE.md), [Resilience/Guardian](VEYRA-RESILIENCE.md), and this roadmap. Existing installed/Live paths remain supported during migration.

## Immutable design rules

1. **System environment:** Alpine/musl/OpenRC owns boot, the Linux kernel, physical devices/network, KDE Plasma **packages and matched versions**, system services, the A/B generations and hardware controls.
2. **Persistent user environment:** one shared user rootfs, package database, OpenRC and PID 1 **inside a separate PID namespace** serves all ordinary Linux accounts. Each account has its own UID/GID, credentials, session and private `/home/LOGIN`; accounts do not get separate rootfs/package databases. The environment also has mount/user/network/IPC namespaces, services and applications; inner `sudo` grants root only there. Default login for every account starts directly in this environment, never through a manual container-entry command or `--user` flag. Both environments share one kernel.
3. **KDE-only desktop:** KDE, KWin, Frameworks, Qt, `plasmashell`, KRunner and plugins are a **version-coherent system-owned deployment**. `plasmashell` and KRunner processes execute in the **user environment** from a read-only system-paired KDE runtime; Alt+F2 and all user app launch paths stay user-side.
4. **No arbitrary package bans:** a user may install another kernel or DE package inside their environment without replacing the active system kernel or supported KDE session. Enforce this at privilege/mount/device/namespace boundaries, not by matching package names, `sudo` rules, or command exceptions.
5. **VPN only for user traffic:** user VPN, routing, DNS and kill switches operate in the user network namespace. System updates and system services continue using the independent host network.
6. **Filesystem-independent A/B:** distinct directory trees, generation-specific package database and kernel/initramfs, independently persistent user state; ext4, XFS, F2FS and Btrfs without required snapshots, reflinks, CoW or A/B partitions.
7. **Two different recovery scopes:** user-environment repair when the system boots; independent Veyra Recovery Environment (VRE) when the system does not. VRE has its own kernel/initramfs and runs *instead of* the main installation.
8. **No untested product claims:** source, scripts, probes, QEMU boot and production readiness are different milestones. Default enablement requires reproducible tests.
9. **Independent smooth recovery:** Guardian and a system TTY survive user-shell loss; independent VRE can recover either system A/B or user SnapCore state. A single shared, privileged Recovery Engine enforces consent and isolation.
10. **User snapshots without mandatory CoW filesystem:** future SnapCore block-level CoW generations must work below ordinary ext4/XFS/F2FS (filesystem support verified separately). A/B boot/rollback must continue to work without snapshots. Personal data needs a separately restorable volume; never silently roll back `/home`.

## Verified code baseline versus unfinished features

| Area | Baseline in main / PR | Still missing |
| --- | --- | --- |
| Alpine 3.22, OpenRC, KDE Live ISO | Existing conventional image and installer tests | Final dual-environment installed runtime |
| Desktop installer | PR #15 merged; local 2026-10-23 clean ext4 qcow2 install/reboot passed with the installed X11 SDDM config, no copied Live config, and tty1 reserved | Graphical Calamares click-through and an installed SDDM greeter/session check |
| Atomic boot | Offline FS-neutral staging, GRUB/initramfs selectors, and a local disposable ext4 QEMU run through confirmed B, failed trial C, automatic fallback to B, and explicit rollback to A; user roots were test fixtures | Signed paired system/user updates, production fallback guarantees, and power-loss-safe transactions |
| Dual environments | PRs #8–13 **merged into `main`**: namespace probes; Alpine user-root/OpenRC PID 1; multi-ID mapping and inner `sudo`; QEMU lifecycle manager, rootfs staging, descriptor checks, pidfd safety. PR #30 is a separate shared-root multi-account authentication proof | Installed manager and login, real host privilege-boundary audit, production user storage/KDE/network integration |
| VPN isolation | Design | veth/network policy, DNS, user VPN and kill-switch tests |
| KDE cross-boundary launch | Design and experimental KRunner preflight in PR #8 | System-selected read-only KDE runtime, user session, safe Alt+F2, D-Bus/Wayland integration |
| vpkg | APK-derived prototype; Go CLI now has ordered Alpine APK → Veyra APK → Nix install resolution | Behavioral validation in the user root, installed-engine packaging, full user-root integration and inactive-generation updater |
| glenv/Nix | Signed runtime pairing and Nix prototypes | Full lifecycle/integration in user root and system generations |
| VRE | Separate console Recovery boot in diskless QEMU | Manual GRUB entry, authenticated artifacts, shared dual-scope restore backend, real repair UI and automatic recovery |
| SnapCore user snapshots | **Design only**: [block-level CoW engine](VEYRA-SNAPCORE.md), no directory-copy snapshots or required Btrfs | On-disk engine, kernel block interface, crash-consistent snapshots, preservation/rollback QEMU proofs |
| Guardian / Resilience | **Design only**: [independent health, UI and recovery policy](VEYRA-RESILIENCE.md) | System OpenRC monitor, trusted graphics/TTY, shared transaction engine and end-to-end disaster recovery |

**Last verified `main` baseline:** commit [`1754933`](https://github.com/angyedz/Veyra-Linux/commit/1754933123564d621081788f7a6ca41a29dd5dd3) from 2026-10-20 passed integration and Stage 1 QEMU ([CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39452117275), [QEMU](https://github.com/angyedz/Veyra-Linux/actions/runs/39452117206)); PRs [#8–13](https://github.com/angyedz/Veyra-Linux/pull/13) are merged. PR [#15](https://github.com/angyedz/Veyra-Linux/pull/15) merged on 2026-10-22 at [`877e456`](https://github.com/angyedz/Veyra-Linux/commit/877e45616e583c6e85eaa1a3764bea2a855e3daf) after integration and ISO/QEMU install checks passed on its head ([integration](https://github.com/angyedz/Veyra-Linux/actions/runs/39574207595), [ISO/install](https://github.com/angyedz/Veyra-Linux/actions/runs/39574207601)). Fresh checks on the merge commit are pending. Neither result proves Calamares GUI clicks, the installed dual-environment system or a general host-escape security review.

## Release levels and publication gates

The first public ISO is **Veyra Linux Pre-Alpha**. It may have unfinished features and known bugs, but SDDM login, the package workflow, basic user environments, and a working A/B update/rollback path on the first supported target must be demonstrated. Choose a version/tag after the candidate is verified; the current conventional single-root ISO is only an internal installer/driver validation image and must not be described as the Pre-Alpha release.

### Internal installer validation (not a release)

Keep the current conventional Alpine/KDE image available for development and for isolating installer, SDDM and package-repository defects. Continue to require a clean graphical install and first Plasma login before using it as the base for the dual-environment installer. Do not publish it as the Veyra Linux Pre-Alpha or imply it contains the two-environment architecture.

**QEMU Live smoke check (2026-10-23):** the rebuilt internal ISO selected the X11 SDDM greeter and started the Wayland Plasma session (`sddm-helper`, `kwin_wayland` and `plasmashell` were present). This verifies the Live login path only; it does not verify the installed SDDM greeter/session.

**Clean ext4 install smoke check (2026-10-23):** `tests/test-installed-qemu.py` installed the ISO into a fresh 20 GiB qcow2 disk, verified the installed SDDM configuration and absence of the Live autologin fragment, then booted the installed system successfully. This uses the shell-driven installer path and serial console; graphical Calamares interaction and the installed SDDM greeter/session remain unverified.

### Veyra Linux Pre-Alpha

The Pre-Alpha target is a working, updateable x86_64 system validated on ext4 in QEMU. It may have rough edges and defer VPN isolation, SnapCore, Guardian, graphical recovery, other filesystems and physical-hardware qualification. It must provide these core behaviors:

- [ ] Clean Calamares install boots through SDDM and reaches a usable KDE session.
- [ ] Normal authenticated login starts in the persistent shared user Linux environment by default. Accounts keep separate Linux identities and private `/home/LOGIN`; the user environment has its own rootfs, package database and init. Inner `sudo` cannot administer the system environment.
- [ ] `vpkg` operates only in the user environment and resolves each install in order: configured Alpine APK repositories, signed `veyra-pkgrepo` (also APK format), then Nix if the package is absent from both APK sources. The Veyra repository contains both system and user packages; system packages are applied only by the trusted updater or, after entering the password-gated system shell, with ordinary system `apk`. `vpkg` has no system-root target mode.
- [ ] A signed release manifest identifies the compatible system and user-environment APK package sets for the Pre-Alpha channel.
- [ ] The updater stages system changes into an inactive A/B generation and stages a matching user-environment generation whenever the release changes that environment or its compatibility contract. It verifies repository/package signatures and release metadata before activation.
- [ ] A trial boot confirms health of both environments. Missing confirmation or a forced boot failure returns to the previous confirmed system/user generation pair. The QEMU test proves A → updated B → forced failure → restored A.
- [ ] `/home`, user Nix/Flatpak state and other declared personal data stay outside both update generations and survive successful updates and system/user generation rollback. Compatible package selections and configuration are migrated explicitly; an unsafe migration blocks activation.
- [ ] The release includes the exact tested ISO, SHA-256/SHA-512, source and package manifest, update instructions and a clear list of unfinished features.

**Gate:** all items above pass on a fresh x86_64/ext4 QEMU install, including SDDM, default user-environment login, package operations, a signed update delivered through the configured repository, and automatic rollback after an intentionally failed trial boot. Release notes must say that other filesystems and physical hardware remain unqualified. No public Pre-Alpha is published from the current single-root image.

### Stable Veyra

Stable release additionally requires Stage 11 security/reliability and Stage 12 release-readiness gates, including supported hardware/filesystem qualification, signed reproducible updates, independent recovery, and a reviewed support/upgrade policy. Unfinished SnapCore or recovery behavior must never be advertised as available.

### Stage progress at a glance

| Stage | State as of 2026-10-22 | Evidence / next boundary |
| --- | --- | --- |
| **0 — Experimental audit/CI** | **Merged QEMU/static baseline** | PR #8; threat model still incomplete |
| **1 — Persistent user environment** | **QEMU prototype milestones passed**, not deployed | PRs #9–13; production OpenRC service, default login and A/B-independent storage pending |
| **1S — SnapCore snapshots (parallel research)** | **Architecture only; no prototype** | CoW block-map engine, immutable generations, FS-specific tests and safe user rollback pending |
| **2 — System/user isolation** | **Partial defensive proofs only** | Rootfs validation, FD filtering and pidfd tests; full adversarial host boundary unproven |
| **3 — User network/VPN** | Not integrated | Virtual link, independent routing/DNS/TUN and VPN tests pending |
| **4–5 — KDE/launch paths** | Architecture and early launcher preflight | Version-locked system KDE with user-executed Plasma/KRunner still pending |
| **6 — vpkg/glenv/Nix** | Existing component prototypes | User-root and A/B integration pending |
| **7 — Filesystem-neutral A/B** | System-only experimental ext4 QEMU cycle passed locally; fixture user roots were synthetic | Signed paired update and broader fault-injection/recovery gates remain pending |
| **8 — Coherent KDE A/B** | Planned | Matched runtime activation/rollback pending |
| **9 — Recovery** | Independent console VRE QEMU proof; **Guardian/Resilience design recorded** | Shared online/VRE repair engine, system A/B + user SnapCore restore, independent TTY and trusted graphical UI pending |
| **10–12 — Installer, QA, release** | Not release-ready | Dual-root installed path and qualification pending |

## Stage 0 — Audit experimental PR #8 and establish gates

**Status:** **PR #8 merged into `main` on 2026-10-20.** Initial static/negative test and QEMU primitive gates passed. This closes the *PR/CI baseline milestone*, **not** the full Stage 2 threat-model audit or production isolation.

- [x] Review old namespace, KRunner and UID-map scripts; label single-UID/bootstrap-only constraints.
- [x] Add conservative canonical rootfs, ownership and submount preflight; add `--check` without launching namespaces.
- [x] Fail closed if KRunner's namespace, private D-Bus or provisional read-only KDE runtime preflight is missing.
- [x] Separate namespace-support **SKIP (77)** from a failed invariant after entering namespaces.
- [x] Pass rootless negative tests and shellcheck in GitHub Actions; inspect run logs. Evidence: [integration CI success, 2026-10-19](https://github.com/angyedz/Veyra-Linux/actions/runs/39301689918).
- [x] Report **SKIP (77)** explicitly when the GitHub runner prohibits unprivileged namespaces. In addition, run a **real disposable, networkless QEMU kernel test**: a nonroot guest process creates a user namespace, a trusted guest supervisor installs UID/GID mappings, and the nested process proves PID 1, mount/network/IPC isolation and inability to read a root-only guest file. Evidence: [QEMU namespace smoke test, 2026-10-19](https://github.com/angyedz/Veyra-Linux/actions/runs/39301689815).
- [x] Merge [PR #8](https://github.com/angyedz/Veyra-Linux/pull/8) into `main` (2026-10-20), without switching the installed/Live boot flow to the experimental user environment.
- [x] Extend the QEMU baseline with targeted rootfs substitution and inherited-FD regressions in [merged PR #12](https://github.com/angyedz/Veyra-Linux/pull/12); separate `pidfd` signal-safety regression in [merged PR #13](https://github.com/angyedz/Veyra-Linux/pull/13).
- [ ] Complete the **production threat-model review** (all inherited capabilities, kernel attack surface, runtime provenance, cross-boundary sockets, mount and device policy). The targeted QEMU checks do not constitute comprehensive security sign-off.

**Gate:** syntax, static, negative tests and real namespace primitives in disposable QEMU **passed**, and PR #8 was merged. **Still not a production isolation sign-off**: full threat-model review and installed service are separate outstanding gates.

## Stage 1 — Persistent user Linux environment

**Depends on:** Stage 0.

**QEMU baseline milestone (PR #9):** a disposable Alpine 3.22 user rootfs booted through its own BusyBox PID 1 and OpenRC on the same guest kernel, with separate user/PID/mount/network/IPC/UTS namespaces, mapped inner root/normal UIDs, namespace-local sudo and persistent state over two VM boots. [QEMU evidence](https://github.com/angyedz/Veyra-Linux/actions/runs/39308988112).

**Account model:** the rootfs and package database are shared by all ordinary accounts in the user environment. Each account authenticates as a distinct Linux UID/GID and receives a private home directory and session. [PR #30](https://github.com/angyedz/Veyra-Linux/pull/30) is a disposable QEMU authentication proof for this model; even if its test passes, production SDDM/PAM integration, account provisioning, system service supervision and security review remain open.

**QEMU lifecycle milestone (PR #10):** the system-side test manager passed start/status/stop, restart and nested PID 1 crash detection; rootfs checks rejected entries outside mapped ownership, an unapproved setuid file, a nested mount and a block device. Two guest boots reused one disk and finished with counts 2 then 4. [QEMU evidence](https://github.com/angyedz/Veyra-Linux/actions/runs/39312323358) · [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39312323395) · [Stage 1 prototype details](STAGE1-USER-ROOTFS.md). This remains a disposable prototype, not a production login path or security sign-off.

**Manager-exit cleanup milestone (PR #11):** QEMU killed the system-side manager while the user environment was running, verified that launcher death terminated nested PID 1, then restarted the manager and confirmed STOPPED plus stale-socket recovery. The same persistent disk passed two guest boots with counts 3 then 6. [QEMU evidence](https://github.com/angyedz/Veyra-Linux/actions/runs/39318056661) · [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39318056566). This is still a prototype lifecycle check, not production crash recovery or a host security sign-off.

**Rootfs and inherited-descriptor hardening (merged PR #12):** the system-side manager retains the validated rootfs directory FD, binds it from the FD to a trusted, non-writable **system-controlled staging mount**, and lets the child bind only that pinned stage instead of re-resolving a mutable user-controlled path. Readiness also uses the validated FD. QEMU exercises an actual visible-mount-name substitution, verifies the originally pinned inode remains selected, rejects escaping `/sbin/init` symlinks with `openat2(RESOLVE_IN_ROOT)`, and checks fail-closed launcher/nested-init FD allowlists. [QEMU pass](https://github.com/angyedz/Veyra-Linux/actions/runs/39404374568) · [integration pass](https://github.com/angyedz/Veyra-Linux/actions/runs/39404374542). **Limit:** pinned directory identity does not freeze or authenticate mutable file contents; the VM console FDs 0–2 remain a deliberate test exception.

**Process-signal safety (merged PR #13):** manager uses `pidfd_open` and `pidfd_send_signal` for nested init STOP/timeout handling, rejects missing/stale pidfd handles rather than falling back to a numeric PID, and verifies a reaped task's pidfd returns `ESRCH`. This mitigates PID reuse in the disposable supervisor, **not** the need for production cgroup/service lifecycle controls. [Merged PR #13](https://github.com/angyedz/Veyra-Linux/pull/13) · [passing QEMU on `main`](https://github.com/angyedz/Veyra-Linux/actions/runs/39452117206).

### Verified Stage 1 QEMU milestones

- [x] Prepare a separate persistent Alpine 3.22 ext4 test rootfs and boot a **distinct BusyBox PID 1** that invokes user-environment OpenRC runlevels; system init remains independent.
- [x] Use system-authorized **multi-ID user/group mappings** (inner IDs 0–65535 → guest outer IDs 300000–365535, matching the shared-root account provisioner); verify ordinary inner UID 1000 and real inner `sudo` mapping to **outer UID 300000**, not system UID 0.
- [x] Demonstrate user rootfs persistence across two actual guest boots, with a test OpenRC service's counter reaching 3 then 6 after start/restart/manager-death scenarios.
- [x] Test system-side `start`, `status`, `stop`, restart, forced PID 1 crash reporting, manager-death cleanup, and stale-socket recovery in QEMU.
- [x] Reject hostile rootfs structure in QEMU (outside-mapped owners, nested mounts, block devices, unexpected setuid files, and escaping init symlinks).
- [x] Verify rootfs source-path substitution cannot redirect a mount pinned through the trusted system-side FD staging; keep the validated FD for readiness.
- [x] Verify child FD cleanup beyond explicitly permitted startup channels, and pidfd-based safe signal delivery / rejection of stale targets.
- [x] Merge this QEMU-prototype sequence, [PRs #9–13](https://github.com/angyedz/Veyra-Linux/pull/13), into `main`, with [full CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39452117275) and [QEMU](https://github.com/angyedz/Veyra-Linux/actions/runs/39452117206) passing.

### Still required for the **installed** Stage 1

- [ ] Finalize filesystem-neutral persistent user rootfs/state **outside system A/B**, including `/home`, `/nix`, package DB, permissions, persistence across real system rollback and recovery/migration strategy (only ext4 guest-image persistence is proven).
- [ ] Port the guest-only supervisor into a reviewed, correctly managed **system OpenRC service** with safe provisioning, stop/restart, cgroup/process ownership, crash recovery, cleanup of trusted stage mounts and protected manager controls.
- [ ] Define production `/dev`, `/proc`, `/sys`, `/run`, capabilities and inherited FD 0–2 policy; check isolation against a hostile user environment, not only the QEMU smoke test.
- [ ] Provision real accounts, authentication and inner `sudo` policy **without** the disposable test fixture's `NOPASSWD` rule.
- [ ] Auto-enter the user environment at normal login; prove service lifecycle, shutdown, reboot and persistent user state in a **clean installed VM** rather than a custom initramfs harness.

**Gate:** the **disposable QEMU prototype portion passed** (two user OpenRC guest boots, mapped `sudo`, persistent state, manager lifecycle and focused safety tests). **Stage 1 as an installed feature is still OPEN**: normal interactive login, production supervision, system A/B-independent storage, security review and boot integration are unproven.

## Stage 1S — SnapCore protected user-environment snapshots (parallel R&D)

**Status:** **all proposed / unimplemented** as of 2026-10-20. [SnapCore architecture contract](VEYRA-SNAPCORE.md). This work is separate from system A/B and must not block its snapshot-free filesystem neutrality.

- [ ] Design a versioned **block-level CoW** snapshot format, immutable mapping roots, transactional commit/journal/replay, reference-safe reclamation, integrity and recovery compatibility; **do not substitute copied file trees**.
- [ ] Build a file-backed simulated block-volume engine; prove create/read/write/fork/restore/new-head/delete with overlapping writes, immutable historical points and no full filesystem copy.
- [ ] Property/fuzz and power-cut/`SIGKILL` tests for metadata journaling, flush ordering, ENOSPC, corruption, deletion/pruning and last-known-good protection.
- [ ] Evaluate kernel `ublk` (or reviewed alternative) as a trusted block interface controlled by system OpenRC; prevent user `sudo` accessing backing storage, raw device, metadata or control socket.
- [ ] QEMU mount ext4 over SnapCore, create a **filesystem-consistent** checkpoint (safe freeze/thaw or stopped user init), damage only disposable user-root data, roll back and prove retained historical generations.
- [ ] Validate XFS, F2FS and optionally Btrfs **as ordinary filesystems on the virtual block volume**, with per-FS freeze/flush/restore tests; no filesystem snapshot feature may be required.
- [ ] Design and prove independently restorable user **root OS**, `/home` and other durable state. Restoring user root must preserve a newer personal document by default.
- [ ] Prove **cross-mount deletion** behavior: removing user `/` may also erase writable `/home`; distinguish OS-only recovery of undamaged current documents from separately authorized restore of a previously snapped personal-data volume. Never claim personal files survive deletion without an independent preserved version.
- [ ] Keep SnapCore catalog/store independent of system A/B; boot the recovery reader in independently booted VRE and test snapshot compatibility across system A→B→A.
- [ ] Test space reservation and retention, backend crash, raw device permissions, bad keys, interrupted restore, immutable snapshot protection and external backup limitations.

**Gate:** repeatable QEMU demonstration of genuine block-level CoW, crash-safe snapshots, failed-user-root recovery with unchanged host state and newer personal data, plus independent VRE accessibility and security review. **No box above is implemented yet.**


## Stage 2 — Enforced system/user privilege boundary

**Depends on:** Stage 1.

**Partial QEMU evidence already in `main`:** namespace-local UID remapping, private mounts/network/IPC/PID, rootfs structural rejection, restricted inherited FDs and pidfd signalling. See PRs #9–13 and the Stage 1 QEMU run. These are **not** exhaustive escape tests.

- [x] QEMU-only: reject invalid user-root device nodes/ownership/mounts and leaked system manager socket; clear unwanted startup file descriptors before executing inner init.
- [x] QEMU-only: verify stale pidfd signal targets are rejected; do not target initial PID 1 during nested environment shutdown.
- [ ] Separate mounts, users/capabilities, IPC, process visibility, devices, system bus and network by **kernel** primitives and narrowly designed host services.
- [ ] No writable mount of host root, A/B store, boot files, EFI, host network state or host-only service sockets inside the user environment.
- [ ] Audit inherited file descriptors, proc/sysfs interfaces, mount propagation, device nodes, namespace transitions and seccomp/LSM/cgroups where applicable.
- [ ] Resource quotas/limits protect system services from user process floods, memory exhaustion and fork bombs.
- [ ] Explicit threat model for kernel vulnerabilities and shared-kernel attacks.
- [ ] Add a system-owned, password-authenticated bridge for entering the host root maintenance environment. Validate credentials against system-side PAM; inner `sudo` or a user-root identity alone must never authorize it.
- [ ] Deliver the authenticated session through a system-controlled TTY first, with rate limiting, logout/timeout cleanup and no password or reusable root capability exposed to user-side processes. Add a trusted graphical entry point only after the KDE bridge gates pass.

**Gate:** under inner `sudo`, attempts to modify host kernel state, mounts, packages, boot, devices, host processes and privileged IPC fail; normal inner administration still succeeds. The system root bridge opens only after host-side password verification and closes cleanly without leaving authority in the user environment.

## Stage 3 — User networking and VPN

**Depends on:** Stages 1–2.

- [ ] System retains physical Wi-Fi/Ethernet and host DNS/routing/firewall; user environment gets its own network namespace via a controlled virtual link.
- [ ] Provide scoped TUN/WireGuard support and CAP_NET_ADMIN only inside the user namespace/network scope.
- [ ] Use a private user DNS configuration and test IPv4, IPv6, split tunnels, reconnection and fail-closed VPN kill switches.
- [ ] Plasma network UI may request limited physical Wi-Fi management through an authenticated host bridge; no direct host NetworkManager control from user root.

**Gate:** OpenVPN/WireGuard and a kill switch affect user traffic only; host updates still use host networking with no DNS or route changes.

## Stage 4 — System-owned KDE runtime, user-side processes

**Depends on:** Stages 1–2; aligns with Stages 7–8.

- [ ] Define the read-only system-KDE runtime layout, loader/library/Qt plugin/QML search isolation and per-generation provenance.
- [ ] Keep the supported KWin/compositor/host graphics platform system-managed while `plasmashell`, KRunner and user applications execute under user namespace privileges.
- [ ] Integrate Wayland sockets, input, graphics access, PipeWire, portals, notifications, D-Bus/polkit via constrained bridges only.
- [ ] Ensure no independent user-owned KDE packages are used to supply the supported system Plasma session; user applications can still be installed freely.

**Gate:** Veyra's KDE session launches correctly from a matched system runtime, with no host administration capability in user-side components.

## Stage 5 — Alt+F2 and ALL application launch entry points

**Depends on:** Stage 4.

- [ ] Route system shortcut recognition to a *show-only* request for user KRunner; no host execution of search text.
- [ ] Audit private D-Bus `org.kde.krunner` activation, runner plugins, terminals, application menus, `.desktop` Exec actions, file openers and portals.
- [ ] Ensure user-invoked commands have user-environment PID/mount/user/network namespaces; `sudo` stays inner.
- [ ] If user init/bus/KRunner is broken, **fail closed** and display independent system recovery controls, never host fallback.

**Gate:** automated negative tests from each launch path cannot run host commands; GUI control remains serviceable for repair.

## Stage 6 — vpkg, glenv, Nix and package independence

**Depends on:** Stage 1; integrates with Stage 7.

- [ ] Finish the independent source-derived `vpkg` engine, preserving APK dependency solver, format, signatures and licenses, without requiring the installed `apk` executable.
- [ ] Integrate and behaviorally validate the CLI's Alpine APK → signed `veyra-pkgrepo` APK → Nix install resolution inside the persistent **user** rootfs. Make `vpkg install/remove/upgrade` affect only that root, with no system-root selection flag.
- [ ] Implement separate privileged host A/B transactions for system packages; no in-place change to active deployment.
- [ ] Integrate signed glenv runtime pairing and Nix profiles without opening host privilege boundaries.
- [ ] Preserve package database integrity across failures and reboots.

**Gate:** ordinary user/sudo installs, removes and upgrades arbitrary packages safely in the user rootfs; system A/B files unchanged.

## Stage 7 — Production-capable filesystem-neutral A/B

**Can proceed in parallel with Stages 1–6.**

- [x] System-only disposable ext4 QEMU prototype: boot confirmed A, activate and confirm B, fail trial C, automatically fall back to B, then explicitly roll back and boot A. User roots in this test are synthetic fixtures; this does not qualify the paired updater.
- [ ] Prove the signed, installed system/user update pair on ext4 (then XFS/F2FS/Btrfs compatibility).
- [ ] Implement verified inactive-generation package staging with an independent package database; never mutate active A.
- [ ] Authenticate generation metadata, kernel/initramfs and update artifacts. Add limited trial boots and durable boot-success confirmation.
- [ ] Guarantee fallback across interrupted writes, kernel panic, missing root, hangs and power loss; test actual bad deployments.
- [ ] Preserve independent `/home`, `/nix` and persistent user rootfs across rollback without irreversible data migrations.

**Gate:** scripted fail-injection and power-cut QEMU tests recover the last confirmed generation without data loss.

## Stage 8 — Coherent KDE upgrades and rollback

**Depends on:** Stages 4 and 7.

- [ ] Stage **all** version-matched Qt/KDE Frameworks, KWin, Plasma, `plasmashell`, KRunner, plugins and portal dependencies together.
- [ ] Select the active generation's immutable KDE runtime at boot, then launch fresh user-side KDE processes from that *same* version set.
- [ ] Reject mixed generations in executable/loader/QML/plugin search paths; do not hot-swap live KDE runtimes.
- [ ] Roll back KDE and system boot together, while preserving user applications and settings.

**Gate:** GUI works after A -> B -> A, with recorded binary and loaded-library provenance for each generation.

## Stage 9 — Veyra Resilience: Guardian, user repair and independent VRE

**Depends on:** Stage 1, Stage 1S (for block-snapshot restore), Stage 2 and Stage 7 (for A/B repair). **Status: design only** for Guardian/SnapCore/shared restore UI; independent console VRE boot has an earlier QEMU proof. Specs: [Resilience](VEYRA-RESILIENCE.md), [SnapCore](VEYRA-SNAPCORE.md), [VRE](VEYRA-RECOVERY.md).

### Independent failure detection and display

- [ ] Implement **system OpenRC-owned Veyra Guardian**, independent of user `/usr`, user D-Bus, `plasmashell`, KRunner and inner PID 1, consuming trustworthy lifecycle, session-heartbeat and storage signals.
- [ ] Differentiate a single `plasmashell` crash (bounded restart) from a user PID 1 death, missing rootfs files, a hung session and SnapCore/FS corruption; do **not** auto-rollback on one heartbeat.
- [ ] Provide an independent **system TTY recovery UI** with clear diagnostics and safe offline-VRE handoff when KWin is unavailable.
- [ ] Prototype a **system-owned trusted graphical Guardian recovery surface** when KWin/compositor still works, without user Plasma/D-Bus; design anti-spoofed input and fall back to TTY reliably.
- [ ] Design user-visible statuses and actions (“Рабочее окружение недоступно”, retry, diagnose, select verified snapshot, restore); never claim a snapshot is available before validation.
- [ ] Implement a **calm incident state machine** with trusted system-owned status sources, debounced shell restarts, accurate health wording, disabled unavailable actions, keyboard-accessible diagnostics and explicit TTY/VRE escape routes. See [UX acceptance contract](VEYRA-RESILIENCE.md#calm-incident-experience-executable-requirements).

### One trusted Recovery Engine, two restore scopes

- [ ] Specify **one shared durable Recovery Engine** usable from online Guardian or separately booted VRE; typed, authorized and journaled operations, no privileged arbitrary shell actions from user root.
- [ ] Add **user-root-only SnapCore restore**, requiring stop/quiesce/unmount and verification; preserve newer separate `/home` by default and offer optional full-data restore only with informed confirmation.
- [ ] Save a **pre-restore damaged-state checkpoint** where safe/capacity permits; otherwise explicitly explain risk and refuse or request fresh consent. Do not erase user files automatically.
- [ ] Expose **system A/B rollback, boot repair, user SnapCore restore and diagnostics** in one independent VRE text menu, without requiring binaries from either damaged installed environment.
- [ ] Integrate independent VRE as a manually selectable, authenticated GRUB boot target with working filesystem drivers and signed/verified recovery artifacts; graphics are optional and test separately.
- [ ] Implement generation repair and durable logs without changing protected user rootfs, `/home`, `/nix` or SnapCore catalog as an incidental effect of a system A/B rollback.
- [ ] Never format or reset storage automatically; require explicit authority and confirmation, test clean recovery of failed/aborted transactions.

### Adversarial recovery gates

- [ ] Disposable QEMU: destroy user `/usr` under inner `sudo`; keep **system OpenRC and independent Guardian/TTY** responsive; restore previous SnapCore user-root generation without reverting newer personal files.
- [ ] Disposable QEMU/VirtualBox: deliberately delete user `/` **with a writable `/home` mount** and separately prove truthful loss reporting, retained earlier personal-volume snapshots/backup options, informed volume-scoped restoration, and no user-root access to SnapCore storage.
- [ ] Disposable QEMU: force crash of `plasmashell` alone; verify bounded shell restart or non-destructive notice, **not** full user-volume rollback.
- [ ] Disposable QEMU: corrupt system A/B generation, then both system and user; boot independent VRE and repair the two environments **separately**.
- [ ] Fail-inject broken KWin, broken user bus, missing/corrupt snapshot, ENOSPC, power loss during rollback, lost decryption key and incompatible recovery versions; show accurate failures and preserve last-known-good recovery data.
- [ ] Validate recovery UX with **no valid snapshots** and with unfinished/aborted recovery transactions: no false green status, no fake progress, bounded waiting, replay-safe retries, diagnostic error IDs and a path to offline VRE.

**Gate:** independent user-failure notification and recovery despite destroyed user rootfs; system A/B restoration from a separately booted VRE; no unintended rollback of personal data, no silent destructive actions. **Not yet passed.**

## Stage 10 — KDE-only two-environment installer

**Depends on:** proven Stages 1–9 for default enablement.

- [ ] Update Calamares/TUI to create system deployment trees and independent persistent user rootfs while retaining user's ext4/XFS/F2FS/Btrfs choice.
- [ ] Enforce and validate a Plasma-only session in the current interim Calamares/TUI installer with static and blank-disk QEMU checks; the final separate-root, two-environment installer remains additional work.
- [ ] Provision identity mappings, separate package databases, signed repositories, boot state, recovery entry and system-KDE runtime.
- [ ] Provision protected SnapCore snapshot/backing-store metadata and separately restorable user-root vs personal-data domains **only after** actual CoW/Recovery Engine gates pass; keep basic installation functional if SnapCore is not enabled.
- [ ] Keep Live bootstrap simple and functional; avoid forcing installation-related changes into it.

**Gate:** unattended and graphical install on clean disposable disk, reboot, login, KDE, package install, VPN, update, rollback and repair succeed.

## Stage 11 — Adversarial security, reliability and hardware QA

**Can run continuously; required again before release.**

- [ ] Verify `sudo`, host kernel and device boundaries; install alternate kernel/DE packages as ordinary files without activating them at host level.
- [ ] Fuzz D-Bus/Wayland/portal boundaries and check inherited socket/FD leakage; simulate hostile user root.
- [ ] Stress resource isolation, network failures, interrupted updates, disk full, power cuts, package signature failures and broken init.
- [ ] Fault-inject SnapCore write/journal/GC failures, power cuts, interrupted restore, bad catalog and user-root destruction; prove Guardian, TTY and offline VRE fail safely without overwriting verified snapshots.
- [ ] Test multiple GPUs/drivers, firmware, BIOS/UEFI, filesystem matrix and physical hardware after VM checks.
- [ ] Review and triage identified escape risks and reproducible logs.

**Gate:** release-blocking failures addressed and independent tests reproducible in CI.

## Stage 12 — Integration, delivery and stable release readiness

**Depends on:** all release-blocking gates.

- [ ] Reproducible signed ISO and package repositories, provenance/manifest verification and supported update delivery.
- [ ] Stable `vpkg` UX, KDE-only desktop polish, glenv/Nix integration, KDE networking, VRE/boot UX and documentation.
- [ ] Keep branding Glacier / Ice Blue, using the authentic `branding/veyra-logo.svg`.
- [ ] Publish user/admin troubleshooting, limitations, recovery and upgrade instructions.
- [ ] Run full clean-install, normal boot, broken-boot and rollback release qualification.

**Gate:** reviewed stable release candidate with evidenced boot, isolation, update, rollback and recovery behavior on supported setups. Passing the Pre-Alpha gate does not close this stage.

## Immediate execution order

1. Finish qualifying SDDM/desktop boot and clean graphical installation in the internal ISO workflow.
2. Install the shared user-environment runtime as the default SDDM login, reusing the merged namespace/lifecycle prototypes and authenticating multiple system accounts into one package root with private homes.
3. Turn the system-only A/B QEMU prototype into a signed update transaction, then add matching user-root generations for the x86_64/ext4 alpha target.
4. Replace the current in-place `apk upgrade` utility with a signed, paired-release updater that stages inactive generations, performs a health-confirmed trial boot and rolls back the pair on failure.
5. Run a clean QEMU install → SDDM login → signed update → successful confirmation → injected failed update → automatic rollback cycle while checking user data and package selections.
6. Choose the release version, then publish Veyra Linux Pre-Alpha only from the exact ISO and repository state that passed this cycle; document unfinished VPN, recovery, other-filesystem and physical-hardware support.
7. Continue Stages 2–12: adversarial isolation review; VPN; coherent KDE launch/runtime; full package-manager lifecycle; SnapCore; Guardian/VRE; broader filesystem and hardware coverage.

## First integrated Pre-Alpha acceptance gate

**Veyra Linux Pre-Alpha** is eligible only when a clean x86_64/ext4 QEMU install reaches a working SDDM session inside the default user environment, keeps host root privileged to the system environment, supports the unified APK/Nix package workflow, updates signed system and user package sets into inactive generations, confirms a healthy paired boot, and automatically restores the previously confirmed pair after an injected boot failure. Separate account homes and declared persistent user state must survive both paths. VPN isolation, KDE runtime version-pairing, SnapCore, Guardian and offline VRE remain later release gates unless separately qualified; the Pre-Alpha notes must state those limits plainly.

No checklist item may be marked complete solely because a script or a
GitHub Actions workflow exists; attach actual test evidence.

