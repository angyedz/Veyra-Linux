# Shared glenv runtime for Veyra (integration contract)

Veyra's host remains **Alpine/musl**. The new [glenv Go runtime manager](https://github.com/angyedz/veyra-glenv) is a *development component*, separate from the existing signed `veyra-glenv` Alpine package that currently drives the original [glenv](https://github.com/angyedz/glenv) installer. Do not replace that package or its installer automatically.

## Runtime boundary

- A privileged Veyra deployment manager owns the glenv version store (for example `/var/lib/veyra/glenv`).
- Each release contains a **complete** Debian glibc sysroot and all requested components: runtime loader, Mesa/GLVND/EGL, GTK, PipeWire client libraries **and modules**, TLS/NSS, and the original glenv Wayland explicit-sync shim.
- The kernel, OpenRC, KWin compositor, system PipeWire daemon and desktop portals remain **musl-native**. Applications that need glibc resolve libraries from the selected runtime and communicate with host services over controlled IPC.
- Host and isolated user environment must see the *same immutable generation*, mounted read-only by the Veyra boot coordinator. A symlink alone does not enforce mount isolation or read-only state.

## Transaction boundary (prototype commands)

Start from a trusted **offline** copy of the original glenv prefix (with its complete Debian `sysroot/` and existing Wayland shim). Create a separate staging tree without moving or rewriting the original:

```sh
glenv release prepare-copy /offline/glibc-env /staging/glenv-v1 glenv-v1
glenv release --store /var/lib/veyra/glenv stage /staging/glenv-v1 glenv-v1
glenv release --store /var/lib/veyra/glenv verify glenv-v1
glenv release --store /var/lib/veyra/glenv pair-host veyra-host-v1 glenv-v1
```

`pair-host` creates an **immutable, host-specific record** identifying the Veyra deployment and its matching glenv generation. The same host ID cannot later be repointed to another glenv version. New Veyra deployments get new IDs and mappings. During an early boot, the coordinator supplies the **actual selected host deployment ID** (not an untrusted environment variable supplied by an application):

```sh
glenv release --store /var/lib/veyra/glenv boot-pair-pin veyra-host-v1 /run/glenv/selected
```

An unknown host deployment or a missing/invalid pair **fails closed**. Exposing the exact pinned release into the other mount namespace (at the same stable path) is a separate privileged Veyra operation, not performed by this command.

To roll back **both** components, the future boot coordinator selects the previous Veyra deployment ID from authenticated boot metadata. `boot-pair-pin` then resolves that ID to its *original* glenv generation. Both A and B mappings remain available; an update to B never overwrites A's mapping. Do **not** independently run `glenv release rollback` and assume that Veyra itself rolled back.

## Missing before production

1. Signed and authenticated Veyra host deployment metadata, a signature chain for glenv releases and coordinated update rollback.
2. Trusted ownership, read-only or verity-backed immutable runtime trees, mount namespaces and controlled boot-service ordering for both environments.
3. A safe loader path for normal `execve` plus complete glibc library paths, caches, plugin search, glenv Wayland shim injection and PipeWire modules.
4. Actual Wayland/KWin, graphics acceleration, sound, portal screen-sharing, glibc app and QEMU reboot/rollback tests.

The current CI checks the Go CLI and synthetic A/B host/runtime mappings on Alpine/musl; it does **not** establish that these production requirements are met.

## Opt-in boot helper

`scripts/glenv-boot-pin.sh` is a fail-closed early-boot **preparation** helper. It reads the deployment ID from `/etc/veyra/deployment-id`, requires root, and invokes the versioned glenv manager to pin the matching selected generation at `/run/glenv/selected`:

```sh
sh scripts/glenv-boot-pin.sh
```

The actual `/etc/veyra/deployment-id` and trusted boot deployment selection **do not yet exist** in Veyra's experimental ISO. Consequently the helper is **not enabled as an OpenRC service** and will refuse to run on current systems without an explicitly provisioned ID and runtime store. For CI, `VEYRA_DEPLOYMENT_ID_FILE`, `VEYRA_GLENV_STORE`, `VEYRA_GLENV_PIN` and `VEYRA_GLENV_BIN` override test paths. These overrides must not be exposed to untrusted users in a privileged production boot service.

The helper only pins a symlink. It does **not** mount the runtime into an isolated user environment, verify Veyra host signatures, or install glibc compatibility libraries.

## Manifest integrity limitations

New glenv releases use **format 3** inventories that include file SHA-256, directory/file Unix modes, and Debian symlink targets. Legacy format 2 is readable but cannot detect permission changes. All manifest checks are local integrity checks, **not signed upstream provenance**. The source prefix must be offline or otherwise quiescent. A later authenticated Veyra OTA layer must ensure read-only immutable storage, trusted boot-selected host IDs, and a cryptographic signature chain for both the host and glenv generations before enabling automatic updates.

### Original-prefix safety

The glenv release manager's `stage` operation moves an already prepared staging tree, but refuses to move the installed original `/opt/glibc-env` and directories carrying glenv's `.glenv-prefix` installer ownership marker. First run `prepare-copy` against an **offline** original prefix. The new staged copy intentionally excludes this administrative marker (which could otherwise confuse the original uninstaller), while retaining the Debian sysroot, the original Wayland filter and the runtime libraries. The original directory and its ownership marker remain unchanged.

## Opt-in read-only mount setup (experimental)

The boot-pinned symlink and the application-visible runtime are now distinct: `/run/glenv/selected` points to a **specific verified release**, while `/run/glenv/runtime` is intended to become a read-only bind mount of that release.

After a future trusted boot manager has provisioned the Veyra deployment ID and a prepared glenv version store, the intended order in a **disposable test guest** is:

```sh
sh scripts/glenv-boot-pin.sh
sh scripts/glenv-boot-mount.sh --check
# WARNING: the following changes mount state and needs root:
sh scripts/glenv-boot-mount.sh
```

To prepare a separately rooted user environment **before its mount namespace is created**, the mount helper can also bind the same selected release read-only into `<userroot>/run/glenv/runtime` by setting `VEYRA_GLENV_USER_ROOT`. It refuses symlinked destination components, outside-store selectors and pre-existing mountpoints; failures attempt to unmount partial setup. This does not configure a running user namespace or install an ELF loader entry point.

The runtime mount helper is **not started at boot** and is not included in the ISO's default startup sequence. Its **real read-only bind mounts passed** a privileged test in an isolated Linux mount namespace in [Veyra CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39208283081): both host and user-root views had identical contents and rejected writes. A complete QEMU guest test of the *original Debian sysroot, real glibc applications, Wayland filter and PipeWire* is still missing. Authenticated host boot metadata, cryptographically trusted glenv manifests and enforced immutable generation storage are still required before production activation.

## Signed glenv releases (new opt-in prototype)

The glenv runtime manager now supports Ed25519 detached signature verification (`verify-signed`) and authenticated boot pairing (`boot-pair-pin-signed`). These use a **trusted public key supplied outside the release**, then verify every file, directory mode and symlink in the format-3 runtime inventory.

The safe, opt-in test workflow signs the format-3 release manifest **outside** the release, runs `glenv release stage-signed <staging-dir> <version> <trusted-key>`, then creates a host pair. It requests strict verification with `VEYRA_GLENV_REQUIRE_SIGNATURE=1` and `VEYRA_GLENV_TRUST_KEY=/path/to/trusted-public-key` for **both** `scripts/glenv-boot-pin.sh` and `scripts/glenv-boot-mount.sh`. Missing keys, symlinked key paths, non-root-owned keys, group/world-writable keys, unsigned trees and tampered signed trees fail closed; the mount helper rechecks the signature immediately before the bind mount. The legacy development path remains unsigned when strict mode is not requested.

The [signed boot regression test](https://github.com/angyedz/Veyra-Linux/actions/runs/39212056804) passed on Alpine/musl. A separate [privileged namespace test](https://github.com/angyedz/Veyra-Linux/actions/runs/39212313713) mounted the **signed** release in both host/user views and verified that both binds were read-only and the signature remained verifiable.

**Not production OTA yet:** Veyra's current ISO does not ship an authenticated host deployment ID, established glenv trust key, signed bootloader chain or protected immutable release store. The helpers are not enabled at boot. Environment-variable overrides are for CI and controlled development, not a source of production trust. Root-owned key files and read-only bind mounts do not prevent a privileged writer from modifying the underlying release store or guarantee an atomic system-wide update.
