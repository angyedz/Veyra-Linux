# Veyra Next — executable migration plan

**Status (2026-10-24):** Future development track, not shipped or implemented.  
**Read first:** [Decision record](ADR-0001-ARCHITECTURE-RESET.md) and [component matrix](VEYRA-MIGRATION-MATRIX.md).

## Target experience

A user should install Veyra, boot directly into KDE Plasma/Wayland, open Discord and share a screen with audio, install and play Steam/Proton games, develop software normally, and apply signed OS updates with an understandable reboot/rollback flow. No secondary user OS, glenv command, Distrobox or chroot requirement for ordinary desktop work.

Target components are a **single native-glibc system**, preferably **OpenRC**, one compatible kernel+driver+graphics+desktop stack, user-specific homes and ordinary permissions, persistent data and read-only deployments. A separately booted Recovery environment is allowed; it does not run as another everyday system.

## Stage 0 — retain history, evaluate foundations

- Preserve existing Alpine main, branches, glenv and SnapCore artifacts, tests and original commit history.
- Maintain [legacy architecture](ARCHITECTURE.md), [Dual Environment](DUAL-ENVIRONMENT.md) and [roadmap](ROADMAP.md) as source evidence.
- Inventory candidate glibc/OpenRC bases (including Artix, Gentoo) with actual package repository, kernel, Nvidia driver, 32-bit Vulkan, OpenRC, KDE/Wayland and build tooling support. Do **not** preselect a distribution because it sounds simpler.
- Specify the exact hardware and VM matrix. An RTX 3070 needs physical tests; QEMU without GPU passthrough is not evidence of working proprietary drivers.
- Create the new repository only when the base and reproducible build path are settled. Its name remains undecided.

**Gate:** documented candidate comparison based on reproducible tests, including failed assumptions.

## Stage 1 — usable non-atomic baseline FIRST

- Reproducible base image and installer, native glibc, one host OpenRC, KDE/KWin, portal backend, PipeWire, D-Bus, networking and login.
- Fresh install into disposable disk and subsequent installed boot. Ordinary app launch stays in the current account, not a nested distro.
- Real GPU/driver tests: NVIDIA kernel and userspace version coherence, KMS/EGL/Vulkan, 32-bit graphics, HDMI/audio, suspend/resume when supported.
- Steam + Proton must launch a representative game, not merely open a splash screen. Target Geometry Dash where possible; check input/latency/audio.
- Discord must support a voice call, screen/window sharing via Wayland portals and audio routing; record exact app version and failures.
- Developer toolchains and workflows: Git, SSH, GCC/Clang, Python, Node.js, editor/IDE and package installation must work.

**Gate:** runnable, usable desktop on real hardware. **Call it non-atomic until the next stage passes.** No claims of broad GPU/game compatibility from one device.

## Stage 2 — atomic deployments and publication

- Compare OSTree-style deployments, bootc and existing Veyra filesystem-neutral A/B experimentally on the selected base and OpenRC.
- Define exactly which files are immutable, which state persists in /home and /var, and how system configuration is updated without silently overwriting local changes.
- Stage verified updates outside the running deployment; bind kernel/initramfs/modules/userspace to the same version and keep previous generation intact.
- Add signed artifact and manifest verification, channel tracking, release promotion and a simple developer workflow. The installer ISO and OTA payload may be derived from the same build, but an ISO alone is not a safe updater.
- Offer user-side install/verify/reboot/progress and safe fallback; detect failed trial boots without depending solely on a service that starts after successful boot.
- Test ext4 QEMU A -> B -> A, interrupted downloads, bad signatures, insufficient space, interrupted staging, power loss and boot failure; expand filesystem and hardware coverage separately.

**Gate:** linked, reproducible signed update and rollback tests. Do not call early staging prototypes production OTA.

## Stage 3 — Recovery, trust and Developer Mode

- Adapt independent Recovery and Expert Shell to the new boot/deployment format; never rely on a damaged installed root.
- Provide offline repair, logs and last-known-good selection. No destructive user-data restore without confirmation.
- Investigate Secure Boot/UKI/verity and hardware trust without implying it works universally.
- Developer Mode enables explicit custom deployments and kernel work with clear warning/recovery instructions; normal apps should not require it.
- Retain SnapCore file-backed and ublk/NBD research, but qualify durability, power-loss and filesystem consistency before offering production snapshots.
- Audit privileged update and Recovery APIs, and app/device permissions.

**Gate:** recovery in deliberately broken installed images, signed boot/update checks where claimed, independently reviewed security boundaries.

## Pre-Alpha acceptance matrix

| Area | Must actually work | Prohibited shortcut |
| --- | --- | --- |
| Desktop | KDE Wayland login, desktop, terminal, files, session DBus | Screenshot of Live UI only |
| Graphics | Matching NVIDIA/AMD/Intel stack per tested hardware | Assume glibc guarantees GPU |
| Games | Steam/Proton actual game boot and playable input/audio | Steam installer exists |
| Communication | Discord call + screen share + audio, with recorded limits | Discord window opens |
| Development | Native toolchains and package manager | Mandate Distrobox/chroot |
| Updates | Verified inactive generation, reboot, rollback | Copy files into live /usr |
| Recovery | Independent rescue boot and tested restore | Recovery menu drawn in a mockup |
| Data | /home preserved and migration hazards documented | Roll back user files silently |
| Developer Mode | Custom boot/system changes, explicit trust transition | Disable all protection quietly |

## Work rules

Always identify four separate statuses: **specified**, **implemented**, **QEMU/CI-tested**, **hardware-tested**. A checkbox is only complete with a source commit and supporting logs. Don't force-merge Alpine-era PRs or convert them into requirements in Veyra Next; consult [matrix](VEYRA-MIGRATION-MATRIX.md) first.

Milestones are defined by gates, **not calendar promises**.
