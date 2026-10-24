# ADR-0001 — Veyra architecture reset (2026-10-24)

**Decision:** Change the future product architecture. Preserve the original Alpine-based project and all experiments.  
**Status:** Architecture decision only; no new base, ISO, updater or hardware compatibility claim has been implemented.  
**Related:** [Next plan](VEYRA-NEXT-PLAN.md), [Migration matrix](VEYRA-MIGRATION-MATRIX.md), [Legacy architecture](ARCHITECTURE.md), [Legacy roadmap](ROADMAP.md).

## Why we are changing direction

Veyra started with Alpine 3.22, musl and OpenRC because they provide a small, understandable and controllable Linux foundation. Development produced significant work: KDE integration, glenv, vpkg, separate persistent user OpenRC root, filesystem-neutral A/B deployment prototypes, independent Recovery, SnapCore and multiple QEMU tests.

The two-environment proposal required **two root filesystems and init processes** to share kernel, graphics, display/input, session D-Bus, PipeWire, portals, package/ABI state and host/user security boundaries. glenv added a glibc compatibility layer atop musl. These are interesting engineering achievements but also high maintenance costs for ordinary desktop tasks.

The user-facing goal was never to build two complete Linux installations for their own sake. The goal is an OS where a person can boot KDE, play games, share the screen in Discord, use Steam/Proton, code, install applications and update without breaking the machine.

Principal reasons for superseding the previous installed design:

1. **Desktop compatibility:** Many third-party binaries and games target native Linux glibc. glenv is a useful standalone project, but a mandatory compatibility bridge introduces loader, library, packaging and testing complexity.
2. **Graphics coherence:** Kernel module, NVIDIA proprietary userspace, Vulkan (including 32-bit components), KWin, KDE, PipeWire and portals should be one compatible stack. Splitting userspace and drivers across libc/root boundaries complicates this.
3. **Two init systems do not themselves guarantee security or atomicity:** Nested OpenRC, PID/mount namespaces and special KDE runtime pairing create extra failure modes without replacing signed deployments, verified boot, sandbox policy or Recovery.
4. **Overlapping package systems:** A new general-purpose dependency solver is not required when the selected glibc base has a native package manager. A user-friendly app store can be built separately.
5. **Time to working Pre-Alpha:** Qualifying real-world desktop use, updates and recovery matters more than custom infrastructure for its own sake.

This is a **design cost assessment**, not an assertion that the old code is broken. Historical CI and QEMU runs remain evidence of their narrowly scoped experimental tests, not of production readiness.

## Adopted direction for Veyra Next

- **One normal installed Linux OS**, native **glibc**, with **OpenRC preferred and to be validated**. A single principal PID 1 and one coherent KDE Plasma/Wayland desktop; applications launch directly in a normal user session.
- **No mandatory second user distribution, nested OpenRC, Distrobox or container-entry command** for routine apps, Steam, Discord, IDEs or development.
- **No mandatory glenv** in the new everyday runtime. The glenv repositories and intellectual work remain preserved as independent projects.
- **Read-only/versioned system deployments**, signed authenticated OTA, clear download/verify/reboot flow, last-known-good rollback and separately persistent personal data.
- A native package manager from the selected distribution, with image/deployment tooling for changes to protected system files. Never mutate the active read-only /usr in place as if it were a conventional system.
- **Independent Recovery** with diagnostics and an expert shell. SnapCore research may protect separate user-data volumes, but it is not a prerequisite for system atomicity.
- **Developer Mode** for explicitly creating and booting custom OS images, kernel modifications and system hacking. Trust state and risks must be visible; avoid silently weakening security.
- Preserve KDE-only branding and existing canonical logo at branding/veyra-logo.svg.

**Not selected yet:** Artix, Gentoo or another glibc/OpenRC-capable foundation; package manager; OSTree/bootc versus filesystem-neutral A/B; image format; graphics-driver installation strategy; signed boot implementation. Fedora Atomic and iOS provide design lessons, not an automatic distribution choice.

If a candidate cannot pass a real NVIDIA/game/Discord test, it is not accepted just because it has glibc. OpenRC is strongly preferred; incompatibilities must be measured, not hidden by claiming a boot that has not happened.

## Security, filesystem and update invariants

- An active deployment is immutable by design, not merely made read-only with a mount flag; investigate signature verification/verity and boot trust separately.
- An update is built and staged separately, verified before activation and boot-tested with fallback. A simple renamed directory or signed ISO alone does not prove atomic updates.
- /home and user data survive system rollback. Persistent /var, configuration and app-state migration need explicit contracts; never silently undo personal work.
- Keep the last known good deployment bootable; independent Recovery must not rely on binaries from the broken installed root.
- The normal user remains unprivileged and apps are isolated according to deliberate permission policy. Developer Mode uses explicit authorization, not a hidden permanent trust bypass.
- Test both VM and real hardware; passing QEMU does not prove RTX 3070, gaming, audio or standby support.
- Filesystem independence is a target where practical, but each root filesystem must be qualified rather than assumed safe.

## Rejected default product models

- Alpine musl host plus compulsory nested glibc distro with its own OpenRC.
- Treating glenv as the universal/default way to run ordinary Linux applications.
- Two independent desktop stacks, or system KDE libraries with complex cross-root pairing simply to launch a user app.
- Mandatory Distrobox, VM or separate development container for normal user-facing work.
- Requiring an original replacement package engine or proprietary CoW service before basic gaming and development work.
- Treating an ISO upload as a secure release without an authenticated manifest, channel state and tested update transaction.

These experiments remain preserved in the old source tree. They are *superseded as default product requirements*, not erased.

## Migration and repository policy

**Do not delete, archive, force-push, or rewrite the existing repository.** This remains the complete Alpine-era implementation and historical test baseline. The planned next implementation may use a new clean repository; its name, creation and base have **not yet occurred**. The next repository should reuse reviewed components rather than mechanically copy every assumption.

Do not auto-merge or close existing open PRs. Triage them individually into: directly reusable, adaptable, useful historical proof, or implementation tied to the old dual-root target. Keep links to their original authors, commits and CI. Do not claim old CI passing proves new platform acceptance.

Record licenses/provenance when reusing vpkg (apk-tools-derived), glenv, SnapCore and related tooling.

## Decision consequences

We accept the possible cost of porting Alpine-specific packaging, initramfs, installer, signed OTA and dual-environment services **only after** a native glibc/OpenRC prototype meets real desktop requirements. The experiment may reject a candidate without damaging the existing project.

The product-level direction is decided. The technology choices are pending proof. **No working implementation or release is asserted by this document.**
