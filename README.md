# Veyra Linux

**Lightweight by design. Compatible by nature.**

Veyra Linux is an experimental Linux distribution built on Alpine Linux. It combines a minimal base with flexible software management and an expanded application environment.

## Highlights

- **Lean foundation** — Alpine Linux and OpenRC.
- **Broad application support** — the [glenv](https://github.com/angyedz/glenv) glibc environment alongside native musl.
- **Flexible software management** — Alpine's `apk` and the Nix package manager.
- **Modular setup** — install only the components you want.
- **Open development** — transparent scripts and automated checks.

## Get started

Veyra is in **early development**. The current source tree provides installation scripts and tooling; it is **not yet a verified ready-to-install operating system**.

To try the integration in a disposable Alpine Linux x86_64 VM:

```sh
git clone https://github.com/angyedz/Veyra-Linux.git
cd Veyra-Linux
sudo sh scripts/bootstrap.sh
sh scripts/smoke.sh
```

The setup modifies the running system and downloads third-party software. Review the scripts before running them.

## Building

An experimental ISO build profile is being developed in `images/`. Build instructions will evolve as the image is validated.

## Contributing

Bug reports, ideas and pull requests are welcome. Follow the progress in [GitHub Actions](https://github.com/angyedz/Veyra-Linux/actions).

---

*Veyra Linux is an independent community project. Alpine Linux, glenv and Nix retain their respective licenses and upstream identities.*
