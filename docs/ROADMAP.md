# Veyra Linux development roadmap

**Last reviewed:** 2026-10-21  
**Status:** engineering plan, not a claim that any unfinished component ships.  
**Target:** an installed KDE-only, filesystem-neutral, atomic Veyra with **two independently administered Linux environments on one kernel**, plus separately bootable Recovery.

This plan is ordered by **dependencies and acceptance gates**, not by calendar estimates.
Parallel tracks are intentional; avoid turning prototypes on in the normal boot path until their gates pass. Decisions live in [Architecture](ARCHITECTURE.md), [Dual Environment](DUAL-ENVIRONMENT.md), [Recovery](VEYRA-RECOVERY.md), [SnapCore](VEYRA-SNAPCORE.md), [Resilience/Guardian](VEYRA-RESILIENCE.md), and this roadmap. Existing installed/Live paths remain supported during migration.

## Immutable design rules

1. **System environment:** Alpine/musl/OpenRC owns boot, the Linux kernel, physical devices/network, KDE Plasma **packages and matched versions**, system services, the A/B generations and hardware controls.
2. **Persistent user environment:** its own rootfs, packaging state, OpenRC and PID 1 **inside a separate PID namespace**, mount/user/network/IPC namespaces, normal user account, isolated root via `sudo`, services and applications. Default login is directly in this environment, never a manual container entry or `--user` flag. Both environments share one kernel.
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
| Desktop installer | Experimental shell/QEMU install/reboot path | KDE-only Calamares install into separate system/user roots and real graphical click-through |
| Atomic boot | Offline FS-neutral staging, GRUB/initramfs selectors and QEMU automation | Passing and reviewed full A -> B -> A; authenticated, power-loss-safe updates |
| Dual environments | PRs #8–13 **merged into `main`**: namespace probes; Alpine user-root/OpenRC PID 1; multi-ID mapping and inner `sudo`; QEMU lifecycle manager, rootfs staging, descriptor checks and pidfd safety. Open PR #17 adds system OpenRC autostart and test serial login; draft PR #18 tests separate system/user ext4 roots across two boots; draft PR #20 verifies system-side creation/reuse of two per-account rootfs directories, separate mapped UID/GID ranges, independent state and denied cross-traversal over two boots (latest two-boot QEMU run [39591641887](https://github.com/angyedz/Veyra-Linux/actions/runs/39591641887) and integration CI [39591642084](https://github.com/angyedz/Veyra-Linux/actions/runs/39591642084)) | Installed manager and graphical login/authentication, arbitrary-account provisioning, real host privilege-boundary audit, A/B-independent production user storage, KDE/network integration |
| VPN isolation | Design | veth/network policy, DNS, user VPN and kill-switch tests |
| KDE cross-boundary launch | Design and experimental KRunner preflight in PR #8 | System-selected read-only KDE runtime, user session, safe Alt+F2, D-Bus/Wayland integration |
| vpkg | APK-derived prototype plus early Go frontend | Final installed-engine replacement, user root integration, inactive-generation updater |
| glenv/Nix | Signed runtime pairing and Nix prototypes | Full lifecycle/integration in user root and system generations |
| VRE | Separate console Recovery boot in diskless QEMU | Manual GRUB entry, authenticated artifacts, shared dual-scope restore backend, real repair UI and automatic recovery |
| SnapCore user snapshots | **Experimental file-backed engine v0.2 and test-only NBD/QEMU proofs in open PRs**: PR #14's 28-test suite passes; PR #16 passes ext4 rollback; PR #19 passes six guest boots with separate root and `/home` restore plus full visible test-root-volume deletion while `/home` remains mounted. The root volume is not a booted Alpine `/` | Production block-device service, booted-root recovery, physical-storage/power-loss testing, online filesystem-consistent checkpoints, installed root/VRE integration, independent VRE reader and privilege-boundary review |
| Guardian / Resilience | **Design only**: [independent health, UI and recovery policy](VEYRA-RESILIENCE.md) | System OpenRC monitor, trusted graphics/TTY, shared transaction engine and end-to-end disaster recovery |

**Current `main` baseline (2026-10-20):** commit [`b9668e6`](https://github.com/angyedz/Veyra-Linux/commit/b9668e6d5517535b265da49f979ac519c9cfdfd8), PRs [#8](https://github.com/angyedz/Veyra-Linux/pull/8), [#9](https://github.com/angyedz/Veyra-Linux/pull/9), [#10](https://github.com/angyedz/Veyra-Linux/pull/10), [#11](https://github.com/angyedz/Veyra-Linux/pull/11), [#12](https://github.com/angyedz/Veyra-Linux/pull/12), [#13](https://github.com/angyedz/Veyra-Linux/pull/13) merged. [Integration CI passed](https://github.com/angyedz/Veyra-Linux/actions/runs/39452117275); [Stage 1 QEMU lifecycle passed](https://github.com/angyedz/Veyra-Linux/actions/runs/39452117206). These prove the **test-only** implementation's stated assertions, not an installed dual-environment system or a general host-escape security review. Continue recording failures and guest serial logs for future gates.

### Stage progress at a glance

| Stage | State as of 2026-10-21 | Evidence / next boundary |
| --- | --- | --- |
| **0 — Experimental audit/CI** | **Merged QEMU/static baseline** | PR #8; threat model still incomplete |
| **1 — Persistent user environment** | **QEMU-only prototypes, not deployed:** PR #20 checks two isolated account roots and two-boot state; draft PR #24 adds manifest-driven root provisioning; draft PR #26 connects that manifest to a test authenticated Eve login and separate `/home` (QEMU runs [39618944444](https://github.com/angyedz/Veyra-Linux/actions/runs/39618944444) and [39618944502](https://github.com/angyedz/Veyra-Linux/actions/runs/39618944502)) | Production provisioner and OpenRC service, PAM/SDDM or other graphical login, SnapCore-backed storage, security review and A/B-independent production data remain pending |
| **1S — SnapCore snapshots (parallel research)** | **File-backed CoW prototype and test-only ext4 root/home recovery proof in open PRs**; PR #19 passes six guest boots using host `/dev/nbd0` and `/dev/nbd1`, including a recursive test-volume wipe with separate `/home` mounted and later root/home restores | Storage remains file-backed behind test-only NBDKit; production interface, booted-root integration, physical-device durability, filesystem consistency, VRE and security gates remain open |
| **2 — System/user isolation** | **Partial defensive proofs only** | Rootfs validation, FD filtering and pidfd tests; full adversarial host boundary unproven |
| **3 — User network/VPN** | Not integrated | Virtual link, independent routing/DNS/TUN and VPN tests pending |
| **4–5 — KDE/launch paths** | Architecture and early launcher preflight | Version-locked system KDE with user-executed Plasma/KRunner still pending |
| **6 — vpkg/glenv/Nix** | Existing component prototypes | User-root and A/B integration pending |
| **7 — Filesystem-neutral A/B** | Independent experimental staging/boot track | Installed A → B → A with fault injection still pending |
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

**QEMU lifecycle milestone (PR #10):** the system-side test manager passed start/status/stop, restart and nested PID 1 crash detection; rootfs checks rejected entries outside mapped ownership, an unapproved setuid file, a nested mount and a block device. Two guest boots reused one disk and finished with counts 2 then 4. [QEMU evidence](https://github.com/angyedz/Veyra-Linux/actions/runs/39312323358) · [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39312323395) · [Stage 1 prototype details](STAGE1-USER-ROOTFS.md). This remains a disposable prototype, not a production login path or security sign-off.

**Manager-exit cleanup milestone (PR #11):** QEMU killed the system-side manager while the user environment was running, verified that launcher death terminated nested PID 1, then restarted the manager and confirmed STOPPED plus stale-socket recovery. The same persistent disk passed two guest boots with counts 3 then 6. [QEMU evidence](https://github.com/angyedz/Veyra-Linux/actions/runs/39318056661) · [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39318056566). This is still a prototype lifecycle check, not production crash recovery or a host security sign-off.

**Rootfs and inherited-descriptor hardening (merged PR #12):** the system-side manager retains the validated rootfs directory FD, binds it from the FD to a trusted, non-writable **system-controlled staging mount**, and lets the child bind only that pinned stage instead of re-resolving a mutable user-controlled path. Readiness also uses the validated FD. QEMU exercises an actual visible-mount-name substitution, verifies the originally pinned inode remains selected, rejects escaping `/sbin/init` symlinks with `openat2(RESOLVE_IN_ROOT)`, and checks fail-closed launcher/nested-init FD allowlists. [QEMU pass](https://github.com/angyedz/Veyra-Linux/actions/runs/39404374568) · [integration pass](https://github.com/angyedz/Veyra-Linux/actions/runs/39404374542). **Limit:** pinned directory identity does not freeze or authenticate mutable file contents; the VM console FDs 0–2 remain a deliberate test exception.

**Process-signal safety (merged PR #13):** manager uses `pidfd_open` and `pidfd_send_signal` for nested init STOP/timeout handling, rejects missing/stale pidfd handles rather than falling back to a numeric PID, and verifies a reaped task's pidfd returns `ESRCH`. This mitigates PID reuse in the disposable supervisor, **not** the need for production cgroup/service lifecycle controls. [Merged PR #13](https://github.com/angyedz/Veyra-Linux/pull/13) · [passing QEMU on `main`](https://github.com/angyedz/Veyra-Linux/actions/runs/39452117206).

**System OpenRC/autologin and `/run` isolation test milestone (open PR #17):** the disposable QEMU init runs system OpenRC's default runlevel; its test-only service starts the manager and persistent user environment. Each user start gets a private `devpts` instance and a serial login as inner UID 1000. The login and namespace-local `sudo` cannot see the system `/run` marker or manager socket; `sudo` writes the same marker path in private user `/run`, and the system verifies its own marker remains unchanged. All five starts on each of two boots pass on one persistent ext4 root disk, with the login counter advancing from 1–5 to 6–10. [QEMU evidence](https://github.com/angyedz/Veyra-Linux/actions/runs/39561204413) · [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39561204499). This remains a custom initramfs fixture; the installed image has no production OpenRC service, authenticated login flow or KDE session broker.

**Two-root disk-backed boot milestone (draft PR #18):** a disposable QEMU initramfs mounts an Alpine system root on ext4 `/dev/vda` and a separate persistent Alpine user root on ext4 `/dev/vdb`, then switches root into the system disk's `/sbin/init`. System OpenRC's default runlevel starts the test manager and user environment; the test verifies serial autologin as inner UID 1000. It reuses both ext4 disks across two guest boots and passes the lifecycle and persistence assertions (counter 5 then 10). [QEMU workflow](https://github.com/angyedz/Veyra-Linux/actions/runs/39571077128) · [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39571076777). This is still a disposable Alpine/QEMU prototype; it does not install the manager, provision authentication, boot through the Veyra installer/GRUB or establish production isolation.

**Generic account-root manifest milestone (draft PR #24, stacked on PR #20):** the test-only system provisioner reads a system-root-owned `name:uid-base` manifest, validates account names and disjoint bounded ID slots, then atomically publishes a root from the system-owned template. The QEMU fixture includes a third account, Eve at outer UID/GID base 300000. Its [serial artifact](https://github.com/angyedz/Veyra-Linux/actions/runs/39609053011/artifacts/12349862859) records Eve provisioned on boot 1 and reused on boot 2 with root owner/group/mode `300000:301000:0710`; [QEMU](https://github.com/angyedz/Veyra-Linux/actions/runs/39609053011) and [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39609052643) pass. This proves reusable root-tree provisioning only: the inner account is still the fixture account `veyrauser`, login remains serial autologin, and no installed provisioner or security sign-off exists.

**Named authenticated login with a separate home volume (draft PR #25, stacked on PR #24):** the test-only manager boots Eve in a disposable Alpine/OpenRC environment from ext4 /dev/vda and mounts a distinct ext4 /dev/vdb at /home. It validates the separate device, mapped ownership and private Eve directory, then pins and binds the home volume into the user root. The serial harness confirms BusyBox rejects a wrong password, accepts the test-only password, and the shell runs as inner UID 1000; the guest writes a proof to the separate home volume, which the host observes with mapped outer UID 101000. [QEMU run 39614365786](https://github.com/angyedz/Veyra-Linux/actions/runs/39614365786) passed and its [serial artifact 12351478325](https://github.com/angyedz/Veyra-Linux/actions/runs/39614365786/artifacts/12351478325) was inspected; [integration CI run 39614365329](https://github.com/angyedz/Veyra-Linux/actions/runs/39614365329) passed. PR #25 uses its own test account fixture; it does not consume PR #24's manifest or prove that manifest-created users can log in. This does not test home preservation across rootfs rollback and does not implement the installed account selector, PAM/SDDM, production manager, production SnapCore backend, Plasma/Wayland bridge or security sign-off.

**Manifest-provisioned authenticated login (draft PR #26, stacked on PR #25):** the disposable system-root fixture runs PR #24's provisioner, selects Eve from the trusted `name:uid-base` manifest at outer UID base 300000, and launches the named-password login path from that provisioned root. QEMU run [39624686356](https://github.com/angyedz/Veyra-Linux/actions/runs/39624686356) and inspected serial artifact [12355518852](https://github.com/angyedz/Veyra-Linux/actions/runs/39624686356/artifacts/12355518852) confirm a wrong password was rejected, login succeeded as inner UID 1000, and a proof written on separate ext4 `/home` was owned by outer UID/GID 301000. The companion named-login QEMU run [39624686263](https://github.com/angyedz/Veyra-Linux/actions/runs/39624686263) and inspected artifact [12355744403](https://github.com/angyedz/Veyra-Linux/actions/runs/39624686263/artifacts/12355744403) also pass; user-lifecycle QEMU [39624686304](https://github.com/angyedz/Veyra-Linux/actions/runs/39624686304) and integration CI [39624686398](https://github.com/angyedz/Veyra-Linux/actions/runs/39624686398) pass on the same head. The change proves one fixture account can traverse generic host-root provisioning into test authentication; the manifest, password setup, manager and login remain test-only. It does not provide production credential enrollment, arbitrary graphical account selection, PAM/SDDM, an installed service, root rollback with `/home` preserved, SnapCore integration or security sign-off.

### Verified Stage 1 QEMU milestones

- [x] Prepare a separate persistent Alpine 3.22 ext4 test rootfs and boot a **distinct BusyBox PID 1** that invokes user-environment OpenRC runlevels; system init remains independent.
- [x] Use system-authorized **multi-ID user/group mappings** (inner IDs 0–65535 → guest outer IDs 100000–165535); verify ordinary inner UID 1000 and real inner `sudo` mapping to **outer UID 100000**, not system UID 0.
- [x] Demonstrate user rootfs persistence across two actual guest boots, with a test OpenRC service's counter reaching 3 then 6 after start/restart/manager-death scenarios.
- [x] Test system-side `start`, `status`, `stop`, restart, forced PID 1 crash reporting, manager-death cleanup, and stale-socket recovery in QEMU.
- [x] Reject hostile rootfs structure in QEMU (outside-mapped owners, nested mounts, block devices, unexpected setuid files, and escaping init symlinks).
- [x] Verify rootfs source-path substitution cannot redirect a mount pinned through the trusted system-side FD staging; keep the validated FD for readiness.
- [x] Verify child FD cleanup beyond explicitly permitted startup channels, and pidfd-based safe signal delivery / rejection of stale targets.
- [x] Merge this QEMU-prototype sequence, [PRs #9–13](https://github.com/angyedz/Veyra-Linux/pull/13), into `main`, with [full CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39452117275) and [QEMU](https://github.com/angyedz/Veyra-Linux/actions/runs/39452117206) passing.
- [x] In open PR #17's disposable QEMU, start the system-side manager from the system OpenRC default runlevel, auto-start the persistent user environment, and verify serial login as inner UID 1000. Test that user UID 1000 and namespace-local `sudo` cannot see the system `/run` marker or manager socket, while the same marker path is writable only in private user `/run`; repeat across two boots on one ext4 root disk (counter 1–5 then 6–10). The fixture also mounts a private `devpts` instance for PTY-based `sudo`. [PR #17 QEMU](https://github.com/angyedz/Veyra-Linux/actions/runs/39561204413) · [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39561204499). The service and no-password serial login remain test-only.
- [x] In draft PR #18's disposable QEMU, boot separate system and user Alpine ext4 disks (`/dev/vda` and `/dev/vdb`), switch into the system disk's OpenRC PID 1, and verify OpenRC starts the manager, the separate user environment and serial autologin as inner UID 1000. Reuse both disks for two boots and verify lifecycle and persistent-state markers (counter 5 then 10). [PR #18 QEMU](https://github.com/angyedz/Veyra-Linux/actions/runs/39571077128) · [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39571076777). This proves the disposable disk-backed test path only; it does not install the service or provide a production login/security sign-off.
- [x] In draft PR #24, provision three configured account roots from a system-owned manifest; QEMU confirms a third root (`eve`, UID/GID base 300000) is atomically created and reused across two boots. This is still a host-side root-tree proof with the fixture's shared inner account and no password-authenticated login. [PR #24 QEMU](https://github.com/angyedz/Veyra-Linux/actions/runs/39609053011) · [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39609052643) · [serial artifact](https://github.com/angyedz/Veyra-Linux/actions/runs/39609053011/artifacts/12349862859).
- [x] In draft PR #25, reject a wrong password, authenticate Eve as inner UID 1000, and verify a separate ext4 `/home` is mounted with mapped owner 101000. This remains an independent test fixture and does not consume PR #24's account manifest. [PR #25 QEMU](https://github.com/angyedz/Veyra-Linux/actions/runs/39614365786) · [serial artifact](https://github.com/angyedz/Veyra-Linux/actions/runs/39614365786/artifacts/12351478325) · [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39614365329).
- [x] In draft PR #26, connect the manifest-provisioned Eve root (outer UID base 300000) to the password-login fixture, reject an incorrect password, authenticate as inner UID 1000, and observe separate `/home` ownership as outer UID/GID 301000. Both latest serial artifacts were inspected. The fixtures, credentials and manager remain test-only. [Manifest-auth QEMU](https://github.com/angyedz/Veyra-Linux/actions/runs/39624686356) · [serial](https://github.com/angyedz/Veyra-Linux/actions/runs/39624686356/artifacts/12355518852) · [named-login QEMU](https://github.com/angyedz/Veyra-Linux/actions/runs/39624686263) · [serial](https://github.com/angyedz/Veyra-Linux/actions/runs/39624686263/artifacts/12355744403) · [lifecycle QEMU](https://github.com/angyedz/Veyra-Linux/actions/runs/39624686304) · [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39624686398).

### Still required for the **installed** Stage 1

- [ ] Finalize filesystem-neutral persistent user rootfs/state **outside system A/B**, including `/home`, `/nix`, package DB, permissions, persistence across real system rollback and recovery/migration strategy (only ext4 guest-image persistence is proven).
- [ ] Port the guest-only supervisor into a reviewed, correctly managed **system OpenRC service** with safe provisioning, stop/restart, cgroup/process ownership, crash recovery, cleanup of trusted stage mounts and protected manager controls.
- [ ] Define production `/dev`, `/proc`, `/sys`, `/run`, capabilities and inherited FD 0–2 policy; check isolation against a hostile user environment, not only the QEMU smoke test.
- [ ] Provision real accounts, authentication and inner `sudo` policy **without** the disposable test fixture's `NOPASSWD` rule.
- [ ] Integrate authenticated normal login into the user environment; the PR #17 serial getty autologin is only a disposable fixture. Prove the graphical/session-broker path, service lifecycle, shutdown, reboot and persistent user state in a **clean installed VM**.

**Gate:** the **disposable QEMU prototype portion passed**: two user OpenRC guest boots, mapped `sudo`, persistent state, manager lifecycle and focused safety tests; open PR #17 proves system OpenRC default-runlevel autostart and test-only serial login, and draft PR #18 adds separate disk-backed system/user roots with two-boot persistence. **Stage 1 as an installed feature is still OPEN**: production supervision, authenticated graphical login/session integration, A/B-independent storage, security review and boot integration are unproven.

## Stage 1S — SnapCore protected user-environment snapshots (parallel R&D)

**Status:** the experimental file-backed v0.2 engine is in [PR #14](https://github.com/angyedz/Veyra-Linux/pull/14); all 28 unit tests pass in [SnapCore CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39572601852), with [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39572601927) passing. Dependent [PR #16](https://github.com/angyedz/Veyra-Linux/pull/16) proves a single ext4 volume through the host kernel NBD frontend. [PR #19](https://github.com/angyedz/Veyra-Linux/pull/19) passes [QEMU CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39572601892) and [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39572601927): six guest boots use separate file-backed SnapCore ext4 volumes exported through host `/dev/nbd0` and `/dev/nbd1`. The test restores a checkpointed root file without rewinding current `/home`; it then deletes every visible entry on the disposable user-root volume while writable `/home` stays separately mounted, restores the root checkpoint and verifies a newer personal file remains, before explicitly restoring the earlier `/home` checkpoint. Both filesystems pass `e2fsck -f -n`. The root volume contains fixture data, not a complete booted Alpine user root. This is test-only NBD/QEMU evidence, not a production block backend, a booted-root destruction test, physical-storage or power-loss proof, online filesystem-consistent checkpointing, installed integration, Guardian or VRE reader. System A/B remains independent of SnapCore.

- [x] Prototype a versioned file-backed **block-level CoW** store with immutable extents and mapping roots, checksummed journal replay, partial writes, checkpoints and rollback into a new writable head. All 19 tests pass in dedicated and full integration CI on commit `17a8834` (links above). This is a simulated engine milestone, not a production-format decision.
- [x] Exercise process termination before immutable extent/root publication, after extent/root sync, in the middle of a multi-block write, during partial journal append, after full append before sync, and after journal sync; test checkpoint, rollback and checkpoint-deletion journal commits. Reopen, retry writes, verify valid history and confirm the last-known-good snapshot remains available. A deterministic 160-operation reference-model sequence also crosses reopen boundaries and restores retained snapshots. Add crash/retry coverage for orphan collection. This does not prove physical power-cut or hardware write-cache behavior.
- [x] Add journaled snapshot-name deletion and reference-aware collection of unreferenced objects; tests prove retained generations/checkpoints remain readable, corrupt live data prevents sweeping, and collection can resume after process death.
- [x] On journal append/fsync errors, poison the in-memory handle and require close/reopen before reading state or continuing writes; inject failures during partial append, after complete append and after `fsync`, then replay and verify a valid prior or committed generation. All 20 tests pass locally and in [dedicated SnapCore CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39505268065) plus [full integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39505267978) on `45bb114`.
- [x] Define a prototype retention policy and implement safe generation pruning. Pruning retains the active head and every named checkpoint, keeps the last N generations, and requires a verified checkpoint; atomic journal replacement allows GC to reclaim pruned maps/extents. Production quota and age-based retention remain open.
- [x] Extend the deterministic reference model with snapshot deletion and GC; verify two independent writer processes serialize through the volume lock and preserve a valid journal chain.
- [x] Add 16 fixed-seed model histories combining partial/sparse writes, checkpoint create/delete, rollback, pruning, GC and reopen; compare active-volume bytes and every retained checkpoint after each operation. Serialize threaded partial writes, reads and checkpoint creation on one shared handle, then verify all byte updates and checkpoints.
- [ ] Continue broader property/fuzz coverage beyond the injected ENOSPC and last-known-good retention regressions.
- [ ] Perform actual power-loss/storage-fault testing for metadata ordering, flush behavior, corruption, deletion/pruning and restart recovery.
- [ ] Evaluate kernel `ublk` (or reviewed alternative) as a trusted block interface controlled by system OpenRC; prevent user `sudo` accessing backing storage, raw device, metadata or control socket.
- [x] In disposable QEMU, format and mount ext4 on the file-backed SnapCore prototype through test-only NBDKit on host kernel `/dev/nbd0`, checkpoint after clean unmount, mutate on a later boot and restore while stopped; verify with `e2fsck -f -n`. [PR #16 QEMU CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39566811188). PR #19 extends the proof to two independent ext4 volumes; storage still uses files and does not prove production `ublk`, physical durability or online filesystem consistency.
- [ ] Validate XFS, F2FS and optionally Btrfs **as ordinary filesystems on the virtual block volume**, with per-FS freeze/flush/restore tests; no filesystem snapshot feature may be required.
- [x] Prove separate user-root and `/home` SnapCore volumes in disposable QEMU: restore a checkpointed root file without rewinding the newer current `/home`, explicitly restore `/home`, then wipe every visible entry on the disposable SnapCore user-root ext4 volume while writable `/home` remains mounted. Restore only the user-root checkpoint and verify the newer `/home` file survives; both ext4 filesystems pass `e2fsck -f -n`. [PR #19 QEMU CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39572601892). The root volume is a test fixture, not a booted Alpine user `/`.
- [ ] Repeat the destructive recovery scenario against a complete, booted Alpine user root with separate writable `/home`, including truthful loss reporting and separately authorized personal-volume restore. Keep this product-level integration gate open.
- [ ] Keep SnapCore catalog/store independent of system A/B; boot the recovery reader in independently booted VRE and test snapshot compatibility across system A→B→A.
- [ ] Keep SnapCore catalog/store independent of system A/B; boot the recovery reader in independently booted VRE and test snapshot compatibility across system A→B→A.
- [ ] Test production space reservation/quotas, backend crash, raw device permissions, bad keys, interrupted restore, immutable snapshot protection and external backup limitations. Prototype pruning/replay tests are tracked above.

**Gate:** still open. The review-branch simulator has 28 unit tests and process-crash/injected journal-failure coverage. PR #16 passes a single-volume ext4 QEMU rollback; PR #19 passes a six-boot, two-volume ext4 proof using host kernel NBD devices and file-backed SnapCore stores, including recursive deletion of all visible test-root volume entries while separate writable `/home` remains mounted and a root-only restore. [QEMU CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39572601892) and [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39572601927) pass on code commit `d50e4d6`. The user-root volume is not booted as a complete Alpine system. Production block backend, booted-root deletion recovery, raw-storage/power-loss behavior, online filesystem-consistent snapshots, independent VRE access, quotas and security review remain required.

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
- [ ] Design and implement an explicit system-administration bridge initiated from the user environment. It may open a dedicated **system-root administrative session only after** the system-side authentication provider accepts an administrator password. The password prompt and authenticated session must stay on a system-controlled trusted TTY/UI; never collect the system password in the user rootfs or expose a host-root mount, root shell socket, reusable credential or privileged control socket to the user environment. Audit successful and failed attempts, expire idle sessions, close broker channels on exit, and fail closed if authentication or the trusted handoff is unavailable.
- [ ] QEMU/security-test the bridge: missing, incorrect, replayed or expired authentication cannot start a session; successful authentication opens a process in the system root environment with system UID 0; hostile user-root processes cannot spoof the trusted prompt, read credentials/session I/O, retain broker descriptors, or turn user-side `sudo` into host root. Keep the bridge disabled until independent security review passes.

**Gate:** under inner `sudo`, attempts to modify host kernel state, mounts, packages, boot, devices, host processes and privileged IPC fail; normal inner administration still succeeds.

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
- [ ] Make normal `vpkg install/remove/upgrade` affect only the persistent **user** rootfs by default, with no environment-selection flags.
- [ ] Implement separate privileged host A/B transactions for system packages; no in-place change to active deployment.
- [ ] Integrate signed glenv runtime pairing and Nix profiles without opening host privilege boundaries.
- [ ] Preserve package database integrity across failures and reboots.

**Gate:** ordinary user/sudo installs, removes and upgrades arbitrary packages safely in the user rootfs; system A/B files unchanged.

## Stage 7 — Production-capable filesystem-neutral A/B

**Can proceed in parallel with Stages 1–6.**

- [ ] Prove full installed QEMU A -> stage B -> boot B -> rollback A -> boot A on ext4 (then XFS/F2FS/Btrfs compatibility).
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
- [ ] Replace *legacy experimental* GNOME/Xfce/LXQt installer choices with fixed KDE-only installed-session policy **after** the new path is validated.
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

## Stage 12 — Integration, delivery and release readiness

**Depends on:** all release-blocking gates.

- [ ] Reproducible signed ISO and package repositories, provenance/manifest verification and supported update delivery.
- [ ] Stable `vpkg` UX, KDE-only desktop polish, glenv/Nix integration, KDE networking, VRE/boot UX and documentation.
- [ ] Keep branding Glacier / Ice Blue, using the authentic `branding/veyra-logo.svg`.
- [ ] Publish user/admin troubleshooting, limitations, recovery and upgrade instructions.
- [ ] Run full clean-install, normal boot, broken-boot and rollback release qualification.

**Gate:** reviewed release candidate with evidenced boot, isolation, update, rollback and recovery behavior on supported setups.

## Immediate execution order

1. **Stage 0 prototype complete and merged**: PR #8 QEMU/static gates verified; continue its unfinished threat-model work under Stage 2.
2. **Stage 1 QEMU baseline merged**: PRs #9–13. Open PR #17 tests system OpenRC autostart and serial login; draft PRs #18, #24, #25 and #26 add two-root boot, generic root provisioning, named login and manifest-to-authentication proofs. **Next** implement the proposed [production account and login contract](STAGE1-LOGIN-DESIGN.md): credential enrollment and the installed OpenRC-owned session manager, then integrate graphical login, finalize persistent roots and personal data outside A/B, and add trusted cleanup. This design does not enable the feature or change the legacy installer.
3. **In parallel Stage 1S:** prototype SnapCore genuine block-level CoW with crash-consistent mapping roots, power-cut tests and independent root vs `/home` recovery; preserve system A/B's snapshot-free contract.
4. Stage 2: adversarially prove the production inner `sudo` cannot escape or control host kernel/devices/boot/network/services; extend inherited-FD/cgroup/LSM audits.
5. Stage 3: controlled user internet and VPN while host network stays independent.
6. In parallel, Stage 7: complete the real A -> B -> A QEMU cycle.
7. Stages 4–5: pair KDE runtime and route all application launch paths.
8. Stages 6 and 8: stabilize user package management and paired system KDE upgrades.
9. Stages 9–12: build system-side Guardian, trusted TTY/graphics fallback and a **shared Recovery Engine** for user SnapCore and system A/B in VRE; then installer, destruction/recovery tests and release qualification.

## First integrated alpha acceptance gate

A **Dual Environment Alpha** is eligible only when a clean QEMU install:
boots system + user init, starts system-owned KDE with user-side
`plasmashell` and KRunner, confines `sudo`, installs normal user packages,
runs a user VPN without touching host networking, persists user rootfs across
reboot and successfully rolls back system A/B independently. A broken user
environment must not prevent the system's maintenance/recovery path. Before advertising snapshots or automatic recovery, a later end-to-end gate must also prove that destroying the disposable user environment triggers **independent Guardian/TTY or VRE**, restores a verified user-root snapshot without rolling back newer separate `/home` data, and that VRE independently repairs a failed system A/B generation. These are **future tasks**, not current alpha claims.

### Distance to the first integrated Alpha (2026-10-21)

**0 of 8 acceptance conditions have been demonstrated together** in one clean,
installed QEMU run. Individual QEMU fixtures cover parts of the design, including
per-account root provisioning, password-authenticated test login, persistence,
and the separate A/B rollback protocol; they do not yet compose into an installed
Dual Environment system.

The remaining integration blocks are production account enrollment and the
system OpenRC/session manager; persistent per-user roots and `/home` outside
system A/B; the system KDE to user Plasma/KRunner session path and a confined
inner-`sudo` policy; user-only package installation and VPN/network isolation;
and a maintenance/recovery path that remains available when the user root fails.
After those blocks, the clean-install QEMU gate must pass end to end, followed by
the required independent security review before enabling the profile. Guardian,
VRE snapshots, and automatic cross-environment recovery remain later work.

No checklist item may be marked complete solely because a script or a
GitHub Actions workflow exists; attach actual test evidence.

