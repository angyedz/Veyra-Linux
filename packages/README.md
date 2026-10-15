# Veyra native packages

The `packages/src/` folder contains our own Alpine APKBUILD recipes.
The `packages/repo/x86_64/` folder is reserved for compiled, signed
`.apk` packages and the signed `APKINDEX.tar.gz`. Alpine's thousands
of packages stay in upstream Alpine repositories.

Initial packages:

- `vpkg` — Go CLI frontend for Alpine APK and user-scoped Nix.
- `veyra-glenv` — APK containing the pinned glenv installer, the **precompiled glenv Go CLI**
  and the Wayland filter shared library. It does **not** embed the full
  Debian/glibc sysroot; setup downloads that on explicit invocation.

Build on Alpine 3.22 with `alpine-sdk go git` and an abuild signing key:

```sh
sh packages/build.sh
```

CI builds APKs and publishes them as workflow artifacts. With stable signing
secrets configured, CI also commits the **compiled signed APK files** and
signed `APKINDEX.tar.gz` into `packages/repo/x86_64/`, and the public
signing key into `packages/keys/`. The private signing key must never
be committed.

Configure two GitHub Actions secrets: `VEYRA_ABUILD_PRIVATE_KEY_B64`
and `VEYRA_ABUILD_PUBLIC_KEY_B64` containing base64-encoded matching
`abuild-keygen` key files. Until these are configured, CI uses an
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
