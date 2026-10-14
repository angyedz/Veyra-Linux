# Veyra Linux (early prototype)

Alpine Linux + OpenRC + [glenv](https://github.com/angyedz/glenv) + Nix package manager, with desktop/VPN compatibility services.

**Status:** integration prototype, not yet a bootable ISO or complete systemd replacement.

## Quick start (disposable Alpine x86_64 VM)

```sh
git clone https://github.com/angyedz/Veyra-Linux.git
cd Veyra-Linux
sudo sh scripts/bootstrap.sh
sh scripts/smoke.sh
```

Bootstrap installs Alpine dependencies, NetworkManager/D-Bus/elogind/polkit, glenv, and multi-user Nix. It makes privileged changes. Review scripts before running. Set `GLENV_REF` to an audited glenv commit to pin the source. `ENABLE_GLENV=0`, `ENABLE_NIX=0`, or `ENABLE_COMPAT=0` skips an integration.

## Compatibility scope

OpenRC is PID 1. NetworkManager, elogind, polkit and D-Bus cover many desktop/VPN requirements, but do **not** implement systemd PID 1 or its full APIs. NetworkManager's dnsmasq integration does **not** provide `org.freedesktop.resolve1`. VPN clients that require systemd units or systemd-resolved need individual compatibility work.

## Development

```sh
sh tests/static.sh
```

GitHub Actions runs syntax and ShellCheck checks. Real glenv/Nix installation and VPN runtime testing are still TODO.

## Roadmap

- Bootable Alpine ISO using an mkimage profile
- QEMU boot and installation smoke tests in CI
- Pin and audit glenv installation
- Test WireGuard, OpenVPN, OpenConnect and Amnezia clients
- Targeted systemd compatibility bridges where necessary
