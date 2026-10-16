# Veyra native packages

Canonical Veyra desktop APKBUILD recipes and sources live in `angyedz/veyra-pkgrepo/src/`. The workflow checks out that repository to `pkgrepo-source/` before building. Only `vpkg` continues to be built from `packages/src/vpkg/` in this distro repository.
The `packages/repo/x86_64/` folder is a **local/CI build output**, not a public package mirror. Signed releases are published to `angyedz/veyra-pkgrepo` under `stable/v1/x86_64/` with a public key in `keys/`. Alpine's thousands of packages stay in upstream Alpine repositories.

Published package families (new packages are published after CI builds succeed):

- Core: `vpkg`, `veyra-glenv`, `veyra-meta`.
- Desktop: `veyra-themes`, `veyra-welcome`, `veyra-settings`, `veyra-appcenter`.
- Maintenance: `veyra-update`, `veyra-repair`, `veyra-session`, `veyra-hardware`, `veyra-driver-manager`, `veyra-compat`.

The first AppCenter version is an APK search/install/remove GUI using KDE's `kdialog` and `pkexec`. Nix is currently supported through the `vpkg` CLI, **not** through the AppCenter GUI. Driver Manager is diagnostic-only; it does not automatically install proprietary drivers. The compatibility utility reports backend availability and does not automatically run foreign binaries. These are early MVP tools, not finished graphical control centers.

Initial packages:

- `vpkg` — Go CLI frontend for Alpine APK and user-scoped Nix.
- `veyra-glenv` — APK containing the pinned glenv installer, the **precompiled glenv Go CLI**
  and the Wayland filter shared library. It does **not** embed the full
  Debian/glibc sysroot; setup downloads that on explicit invocation.

Build on Alpine 3.22 with `alpine-sdk go git`, an abuild signing key, and a checkout of `angyedz/veyra-pkgrepo` at `pkgrepo-source/`:

```sh
sh packages/build.sh
```

CI builds APKs and publishes them as workflow artifacts. On pushes to `main` and manual runs, CI also publishes the **signed APK files** and signed `APKINDEX.tar.gz` to the separate `angyedz/veyra-pkgrepo` repository. It never commits build outputs to the Veyra-Linux source repository. The private signing key must never be committed.

Configure three GitHub Actions secrets: `VEYRA_ABUILD_PRIVATE_KEY_B64` and `VEYRA_ABUILD_PUBLIC_KEY_B64` containing base64-encoded matching `abuild-keygen` key files, and `VEYRA_PKGREPO_TOKEN`, a fine-grained token with Contents read/write access **only** to `angyedz/veyra-pkgrepo`. Until these are configured, CI uses an
ephemeral key and **does not publish packages to the git repository**;
only CI artifacts are generated. Install the matching public key into
`/etc/apk/keys/` before trusting this repository. Never use
`--allow-untrusted` for routine updates.

`vpkg` commands:

```sh
sudo vpkg install firefox
sudo vpkg update
sudo vpkg upgrade
vpkg search firefox
vpkg install helix --from nix
vpkg list --from nix
vpkg upgrade --from nix
```

Nix commands act on the current user's profile. Do not use sudo for Nix
unless you intend to modify root's profile. Alpine release upgrades are
not automatic. `vpkg` does not silently switch package backends.
