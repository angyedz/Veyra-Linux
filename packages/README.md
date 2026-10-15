# Veyra native packages

The `packages/src/` folder contains our own Alpine APKBUILD recipes.
The `packages/repo/x86_64/` folder is reserved for compiled, signed
`.apk` packages and the signed `APKINDEX.tar.gz`. Alpine's thousands
of packages stay in upstream Alpine repositories.

Initial packages:

- `vpkg` — Go CLI frontend for Alpine APK and user-scoped Nix.
- `veyra-glenv` — APK containing the pinned glenv installer, the **precompiled glenv Go CLI**,
  authenticated Debian package helper, and Wayland filter shared library. It
  does **not** embed the full Debian/glibc sysroot; setup downloads that on
  explicit invocation.

Build on Alpine 3.22 with `alpine-sdk go git` and an abuild signing key:

```sh
sh packages/build.sh
```

CI builds APKs and publishes them as workflow artifacts. Pull requests use
temporary signing keys and receive no stable signing secrets. A push to `main`
uses the stable key, and a separate write-scoped job commits the **compiled
signed APK files**, signed `APKINDEX.tar.gz`, and public key into
`packages/repo/x86_64/` and `packages/keys/`. The private signing key must
never be committed.

Configure two GitHub Actions secrets: `VEYRA_ABUILD_PRIVATE_KEY_B64`
and `VEYRA_ABUILD_PUBLIC_KEY_B64` containing base64-encoded matching
`abuild-keygen` key files. Until these are configured, CI uses an
ephemeral key and **does not publish packages to the git repository**;
only CI artifacts are generated. The ISO embeds the public key and uses the
signed repository when stable packages are present. Disk installations retain
that key and add the Veyra repository URL, so `vpkg update` and `vpkg install`
can use the signed Veyra APK repository. Never use `--allow-untrusted` for
routine updates.

`vpkg` commands:

```sh
sudo vpkg install firefox
sudo vpkg update
vpkg update --from nix
sudo vpkg upgrade
sudo vpkg upgrade --check
vpkg search firefox
vpkg install helix --from nix
vpkg list --from nix
vpkg upgrade --from nix
vpkg upgrade --from nix --dry-run
vpkg history --from nix
vpkg rollback --from nix
vpkg rollback --from nix 12
vpkg install ./MyApp.AppImage --from appimage
vpkg history --from appimage
vpkg rollback --from appimage
vpkg inspect ./application
vpkg history --from alpine
sudo vpkg install ./package.deb --from glenv
sudo vpkg install package-name --from glenv
sudo vpkg update --from glenv
sudo vpkg upgrade --from glenv
sudo vpkg upgrade --from glenv --dry-run
sudo vpkg history --from glenv
sudo vpkg rollback --from glenv
vpkg search discord
vpkg install firefox
vpkg install ./package.deb
vpkg install ./MyApp.AppImage
```

Nix commands act on the current user's profile. Do not use sudo for Nix
unless you intend to modify root's profile. Alpine release upgrades are
not automatic. `vpkg` does not silently switch package backends. APK history
shows the read-only `/var/log/apk.log`; Alpine APK does not retain reversible
transaction snapshots, so `vpkg` cannot safely roll back APK operations. Nix,
AppImage, and glenv history and rollback are available.

Without `--from`, `vpkg search` checks enabled APK repositories (including
Veyra) and Nix. `vpkg install` prefers an APK candidate, previews the resolved
APK dependency plan, and asks before installing. If it only finds Nix candidates, it shows
the complete package list and asks before installing them in one profile
operation. Automatic installs require a terminal; non-interactive calls must
pass `--from alpine` or `--from nix`. Local `.deb` and AppImage files are
detected by their file extensions and routed to glenv or the AppImage installer.

The glenv source installs packages into the glenv sysroot, not Alpine's host
filesystem. A local `.deb` is accepted only when its package name, version,
architecture, and SHA256 exactly match the current authenticated Debian index.
The index is verified with `gpgv` and the installed Debian archive keyring.
When glenv uses its default system prefix (`/opt/glibc-env`), run these
commands with `sudo`; a user-owned `GLENV_PREFIX` can be used without root.

AppImage installation checks that the file is a regular ELF for the current
CPU, copies it to the user's `~/.local/opt/veyra-appimages/` directory, and
adds a quoted desktop launcher. The installer never runs the AppImage. It does
not verify the publisher's signature, so only install files from a publisher
you trust. Updates replace the existing copy transactionally; AppImage history
keeps the previous files, and rollback checks that the installed files have
not been changed since the update.

`vpkg inspect` reports ELF architecture, interpreter, direct shared-library
dependencies and GLIBC version strings. It checks direct library filenames
against the configured glenv sysroot when present. The result is static
analysis; a candidate may still need system services, graphics drivers, or
other runtime files.
