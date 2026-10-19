# Veyra Linux

**Lightweight by design. Compatible by nature.**

Veyra Linux is an experimental Linux distribution built on Alpine Linux. It combines a minimal foundation with flexible software management and an expanded application environment.

## Highlights

- **Lean foundation** — Alpine Linux and OpenRC.
- **Broad application support** — the [glenv](https://github.com/angyedz/glenv) glibc environment alongside native musl.
- **Flexible packages** — `apk` and the Nix package manager.
- **Personalized desktop** — choose your interface during installation, with automatic hardware setup.
- **Modular setup** — add only the components you need.
- **Open development** — transparent scripts and automated builds.

## Get started

Veyra is in **early development**. The experimental ISO passed a full **QEMU Live boot → installation onto a blank virtual disk → installed-system reboot** in [GitHub Actions](https://github.com/angyedz/Veyra-Linux/actions/runs/39202330852) on October 19, 2026. This automated test exercises the installer shell scripts, not graphical Calamares clicks; real hardware compatibility is still unverified.

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
