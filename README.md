# Veyra Linux

**Lightweight by design. Compatible by nature.**

Veyra Linux is an experimental Linux distribution built on Alpine Linux. The current development image is a conventional KDE desktop and installer; the planned dual-environment system is still in development.

**Target architecture (not shipped yet):** a KDE-only, atomic installed system with separate system and user Linux environments sharing one kernel. KDE packages are system-managed; `plasmashell` runs in the user environment.

## Highlights

- **Lean foundation** — Alpine Linux and OpenRC.
- **Broad application support** — the [glenv](https://github.com/angyedz/glenv) glibc environment alongside native musl.
- **Flexible packages** — `apk` and the Nix package manager.
- **KDE Plasma desktop** — the final installed Veyra will be KDE-only. The legacy experimental installer still offers other DEs during migration.
- **Modular setup** — add only the components you need.
- **Open development** — transparent scripts and automated builds.

## Development plan

See the [full development roadmap](docs/ROADMAP.md) and the [dual-environment security architecture](docs/DUAL-ENVIRONMENT.md). Stage gates distinguish implemented code, CI probes and fully tested functionality.

## Get started

Veyra is in **early development** and has no public release yet. A first Installer Preview is planned only after a pinned ISO passes Live boot, blank-disk installation and reboot checks, followed by a graphical Calamares install and Plasma login in a disposable VM. The current automated install test exercises installer scripts, not Calamares clicks; real hardware compatibility is unverified. The ISO does not yet ship the planned dual-environment architecture, atomic updates, isolated user VPN, or independent recovery. See the [release gates and roadmap](docs/ROADMAP.md#release-levels-and-publication-gates).

Try the integration in an Alpine Linux x86_64 virtual machine:

```sh
git clone https://github.com/angyedz/Veyra-Linux.git
cd Veyra-Linux
sudo sh scripts/bootstrap.sh
sh scripts/smoke.sh
```

The setup modifies the running system and downloads third-party software. Review it before running.

## Build an image

See [Building Veyra](docs/BUILDING.md) for the ISO workflow and development instructions. CI status and build artifacts are available in [GitHub Actions](https://github.com/angyedz/Veyra-Linux/actions).

## Contributing

Bug reports, feature proposals and pull requests are welcome.

---

*Veyra Linux is an independent community project; upstream projects retain their own trademarks and licenses.*
