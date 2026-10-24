# Migration inventory — what survives Veyra's architecture change

**Date:** 2026-10-24. This is a triage proposal, not a deletion list.  
**See:** [ADR-0001](ADR-0001-ARCHITECTURE-RESET.md).

| Existing component | Disposition for new design | Important qualification |
| --- | --- | --- |
| Alpine 3.22/musl host | **Preserve as historical working source**, replace only if new glibc base passes tests | Do not mutate or rewrite old releases/branches |
| OpenRC | **Keep as preferred host service manager** | Exactly one ordinary OS init in next design; new base service scripts need adaptation |
| glenv / veyra-glenv | **Preserve as separate projects and research** | No longer mandatory on a native glibc desktop; retain licenses and shim work |
| Dual Environment nested OpenRC/rootfs | **Historical prototype / selectively reuse security tests** | Mandatory nested environment is superseded; do not port KDE cross-root launcher logic by default |
| KDE Plasma/Wayland | **Keep** | One consistent KWin/Plasma/Qt/portal/graphics deployment |
| Veyra branding | **Keep** | Continue using branding/veyra-logo.svg, not a replacement emblem |
| vpkg apk-derived engine | **Preserve source; optional future frontend** | Native package manager can handle dependencies; signed OS deployments are separate; preserve apk-tools GPL attribution |
| Nix integration | **Optional, nonessential** | Not required for games, apps or default development |
| Filesystem-neutral A/B staging and bootctl | **Review and adapt, not copy blindly** | Alpine mkinitfs and GRUB assumptions are platform-specific |
| SnapCore + ublk/NBD/QEMU tests | **Preserve research, optionally data snapshot backend** | File-backed tests are not physical, production-safe block snapshots |
| Veyra Recovery + Expert Shell | **Keep and port** | Independent offline boot and shell remain design goals |
| Guardian/Resilience | **Adapt to one system** | No second user PID 1 health requirement |
| Installer/Live/Calamares/TUI | **Port proven UX and tests** | Update package and init-specific bits |
| Signed OTA tooling | **Review and selectively reuse** | Verified manifest and real fail-safe updates needed |
| CI, QEMU, serial logs | **Keep methods and evidence** | VM checks do not prove hardware compatibility |

## Rules for open pull requests

Do not merge or close any open PR solely because this decision was recorded. Examine each individually: (a) directly reusable; (b) needs adaptation; (c) valuable historical proof; (d) targets obsolete mandatory dual-root architecture. Link test logs and acknowledge original code ownership. Branches under active development must not be overwritten.

Historical test results, including namespace boot probes, ext4 QEMU tests, signed updater and recovery experiments, remain valid for **their actual test scope**. None is a claim that Veyra Next has shipped or that a new repository already exists.

## New repository and licenses

A fresh future repository is **planned but not yet created or named**. Do not bulk-copy unfinished components before identifying a new base. When porting code, keep upstream licenses, copyright, third-party references and provenance, including glenv and apk-tools-derived vpkg source.

**Existing source is not wasted work. The architecture target is changing; history stays intact.**
