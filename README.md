# Veyra Linux

**Lightweight by design. Compatible by nature.**

> **Architecture transition — October 24, 2026:** Veyra's future product direction is a **single native-glibc KDE Plasma/Wayland desktop**, **OpenRC preferred**, normal Linux gaming, communications and development, with signed atomic updates and independent recovery. No compulsory second Linux environment, Distrobox or glenv for daily use. The distribution base, update implementation and any new repository are **not yet selected, created or shipped**.
>
> **Start here:** [Architecture decision](docs/ADR-0001-ARCHITECTURE-RESET.md) · [Veyra Next plan](docs/VEYRA-NEXT-PLAN.md) · [Migration matrix](docs/VEYRA-MIGRATION-MATRIX.md).

## Existing Alpine-era implementation

This repository **remains the historical and experimental Alpine 3.22/musl/OpenRC implementation**. Its code and Git history have not been deleted. It includes experiments and tests for Dual Environment, glenv, vpkg, SnapCore, independent Recovery, and filesystem-neutral A/B.

The [former architecture](docs/ARCHITECTURE.md), [dual-environment design](docs/DUAL-ENVIRONMENT.md), and [legacy roadmap](docs/ROADMAP.md) remain readable, but no longer define the future product target. [glenv](https://github.com/angyedz/glenv) remains a preserved standalone compatibility project, not a requirement for the future glibc desktop.

The experimental Alpine ISO passed a **QEMU Live boot → shell-script installation → installed reboot** test on 2026-10-19 ([Actions](https://github.com/angyedz/Veyra-Linux/actions/runs/39202330852)). This is not proof of a final atomic product, graphical Calamares qualification or physical NVIDIA gaming compatibility.

## Legacy source exploration

~~~sh
git clone https://github.com/angyedz/Veyra-Linux.git
cd Veyra-Linux
sudo sh scripts/bootstrap.sh
sh scripts/smoke.sh
~~~

This bootstrap modifies the current system and downloads third-party components; review scripts and use a disposable VM. See [build instructions](docs/BUILDING.md).

**No new Veyra Next installer, ISO or update migration exists yet.** Veyra is an independent community project; upstream trademarks and licenses remain with their owners.
