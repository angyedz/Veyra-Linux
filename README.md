# Veyra Linux

**Lightweight by design. Compatible by nature.**

Veyra Linux is an experimental Linux distribution built on Alpine Linux. It combines a minimal foundation with flexible software management and an expanded application environment.

## Highlights

- **Lean foundation** — Alpine Linux and OpenRC.
- **Broad application support** — the [glenv](https://github.com/angyedz/glenv) glibc environment alongside native musl.
- **Flexible packages** — `apk` and the Nix package manager.
- **Flexible installation** — choose Plasma, GNOME, Xfce, LXQt, or a console-only system; hardware setup is automatic.
- **Modular setup** — add only the components you need.
- **Open development** — transparent scripts and automated builds.

## Get started

Veyra is in **early development**. CI builds the ISO, verifies live boot, and tests installation plus first boot on blank QEMU disks for Plasma and the console-only profile. GNOME, Xfce, and LXQt are validated through configuration, package-resolution, and installer-routing checks; their full disk installation is not yet covered.

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
