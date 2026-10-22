# Veyra native package engine (experimental)

This directory starts the **source-derived** Veyra package manager, instead of making `vpkg` a permanent wrapper around Alpine's executable. The experimental `vpkg-engine` binary is built from **Alpine apk-tools v2.14.12**, pinned to upstream commit `7bf85c7cc18a0b6056f376421fb5d4c2a806daad` and modified by the downstream patch series in this directory.

**Upstream attribution and license:** Alpine apk-tools authors, GPL-2.0-only. The canonical upstream sources are at https://gitlab.alpinelinux.org/alpine/apk-tools and mirrored at https://github.com/alpinelinux/apk-tools. The build retains their full source history and license and publishes the GPL license alongside the test binary. Redistribution of a modified binary requires providing corresponding source and downstream modifications under the GPL-2.0-only terms. This build recipe plus pinned upstream source and patches describes the source used for the binary; maintain a corresponding-source distribution for public releases.

## Current native engine

```sh
# ONLY inside a disposable Alpine 3.22 development environment:
apk add --no-cache git patch pkgconf build-base linux-headers \
  openssl-dev openssl-libs-static zlib-dev zlib-static
sh scripts/build-vpkg-engine.sh
./dist/vpkg-engine/vpkg-engine --version
sh tests/test-vpkg-engine.sh
```

The build uses apk-tools **2.x's Makefile**, compiles a standalone static APK-derived engine under a Veyra-specific executable name, and runs a signed `busybox` package installation in a scratch `--root` with an independent APK database. This verifies the reused Alpine package format, upstream solver and signature-checking path in the experimental binary. It does **not** test transactional updates, bootloader integration, or replacement of all Alpine internal dependencies.

`vpkg`'s source in `vpkg/` now prefers `vpkg-engine` when present on `PATH`. The engine is intended for package operations in the isolated user environment; it does not replace the system's ordinary `apk`. Existing development images still fall back to `apk` until the engine is packaged. With the installed-host marker `/etc/veyra/deployment-mode = atomic-v1`, in-place APK-backend `install/remove/update/upgrade` commands are **rejected**; the frontend does not fall back to `apk`. That marker is **not set** by the current installer because the atomic update transaction backend has not been deployed.

## Replacement gates

Do not uninstall Alpine `apk-tools` from the system environment, Live ISO or working installations. `alpine-base`, `mkinitfs`, `abuild`, installers and system maintenance need the ordinary `apk` command. Package the native engine for the isolated user environment with appropriate ABI/provides/replaces, validate dependency and signature compatibility, implement the package-source fallback, and keep system updates in the trusted inactive-root transaction manager.

The native engine is deliberately called `vpkg-engine` during this transition. A future final package may rename it when the legacy APK command dependencies are handled explicitly. This is a **downstream source-derived build**, not a standalone GitHub fork repository yet.

### Atomic active-root policy (new experimental patch)

The second downstream C patch, `0002-atomic-active-root-guard.patch`, makes the **native engine itself** reject package/database writes against the active root whenever `/etc/veyra/deployment-mode` contains `atomic-v1`. It is a defense-in-depth policy check (not a root-privilege security boundary); the Go frontend enforces the same rule independently. An explicitly addressed, existing inactive `--root` remains usable for staging. Unknown modes fail closed. CI checks the refusal's **nonzero exit code** and the continued usability of an isolated root, as well as signed APK installation. The new mode marker is never installed into the current live or legacy system.

The atomic KDE system package goals are recorded separately in [`deployment/plasma-system-packages.txt`](../../deployment/plasma-system-packages.txt). They are kept outside the Live ISO build; user applications such as Firefox, Dolphin and Konsole are not part of the mandatory system deployment. This package manifest is a **target configuration only**, not evidence that the atomic installed-image workflow has been shipped.
