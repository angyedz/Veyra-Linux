# Veyra native packages

The `packages/src/` folder contains our own Alpine APKBUILD recipes.
The `packages/repo/x86_64/` folder is reserved for compiled, signed
`.apk` packages and the signed `APKINDEX.tar.gz`. Alpine's thousands
of packages stay in upstream Alpine repositories.

Initial packages:

- `vpkg` — Go CLI frontend for Alpine APK and user-scoped Nix.
- `veyra-glenv` — APK containing a pinned glenv setup script. It does
  **not** yet bundle a precompiled Debian/glibc runtime; setup downloads
  components on explicit invocation. Bundling the full runtime reproducibly
  remains future work.

Build on Alpine 3.22 with `alpine-sdk go git` and an abuild signing key:

```sh
sh packages/build.sh
```

CI builds APKs and publishes them as workflow artifacts. A trusted
repository must use a stable signing key, with its **private half stored
only in GitHub Actions secrets**, and its public half distributed to users
via `/etc/apk/keys`. Never use `--allow-untrusted` for routine updates.

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
