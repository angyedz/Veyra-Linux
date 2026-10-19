# Shared glenv runtime for Veyra (integration contract)

Veyra's host remains **Alpine/musl**. The new [glenv Go runtime manager](https://github.com/angyedz/veyra-glenv) is a *development component*, separate from the existing signed `veyra-glenv` Alpine package that currently drives the original [glenv](https://github.com/angyedz/glenv) installer. Do not replace that package or its installer automatically.

## Runtime boundary

- A privileged Veyra deployment manager owns the glenv version store (for example `/var/lib/veyra/glenv`).
- Each release contains a **complete** Debian glibc sysroot and all requested components: runtime loader, Mesa/GLVND/EGL, GTK, PipeWire client libraries **and modules**, TLS/NSS, and the original glenv Wayland explicit-sync shim.
- The kernel, OpenRC, KWin compositor, system PipeWire daemon and desktop portals remain **musl-native**. Applications that need glibc resolve libraries from the selected runtime and communicate with host services over controlled IPC.
- Host and isolated user environment must see the *same immutable generation*, mounted read-only by the Veyra boot coordinator. A symlink alone does not enforce mount isolation or read-only state.

## Transaction boundary (prototype commands)

After preparing an offline release tree and creating its `glenv-manifest.json` format-2 inventory:

```sh
glenv release inventory /staging/glenv-v1 glenv-v1 > /staging/glenv-v1/glenv-manifest.json
glenv release --store /var/lib/veyra/glenv stage /staging/glenv-v1 glenv-v1
glenv release --store /var/lib/veyra/glenv verify glenv-v1
glenv release --store /var/lib/veyra/glenv bind-host veyra-host-v1 glenv-v1
```

`bind-host` atomically writes **one record** identifying a Veyra deployment and its glenv release. During an early boot, the coordinator supplies the **actual selected host deployment ID** (not an untrusted environment variable supplied by an application):

```sh
glenv release --store /var/lib/veyra/glenv boot-pin veyra-host-v1 /run/glenv/runtime
```

A mismatch between the selected Veyra deployment and the binding **fails closed**. Exposing the exact pinned release into the other mount namespace (at the same stable path) is a separate privileged Veyra operation, not performed by this command.

To roll back **both** components, first select the previous Veyra boot deployment using its future OTA boot record and ensure a matching `bind-host` record for that deployment before starting services. Do **not** independently run `glenv release rollback` and assume that Veyra itself rolled back.

## Missing before production

1. Signed and authenticated Veyra host deployment metadata, a signature chain for glenv releases and coordinated update rollback.
2. Trusted ownership, read-only or verity-backed immutable runtime trees, mount namespaces and controlled boot-service ordering for both environments.
3. A safe loader path for normal `execve` plus complete glibc library paths, caches, plugin search, glenv Wayland shim injection and PipeWire modules.
4. Actual Wayland/KWin, graphics acceleration, sound, portal screen-sharing, glibc app and QEMU reboot/rollback tests.

The current CI checks the Go CLI and a synthetic host/runtime pairing on Alpine/musl; it does **not** establish that these production requirements are met.

## Opt-in boot helper

`scripts/glenv-boot-pin.sh` is a fail-closed early-boot **preparation** helper. It reads the deployment ID from `/etc/veyra/deployment-id`, requires root, and invokes the versioned glenv manager to pin the matching runtime at `/run/glenv/runtime`:

```sh
sh scripts/glenv-boot-pin.sh
```

The actual `/etc/veyra/deployment-id` and trusted boot deployment selection **do not yet exist** in Veyra's experimental ISO. Consequently the helper is **not enabled as an OpenRC service** and will refuse to run on current systems without an explicitly provisioned ID and runtime store. For CI, `VEYRA_DEPLOYMENT_ID_FILE`, `VEYRA_GLENV_STORE`, `VEYRA_GLENV_PIN` and `VEYRA_GLENV_BIN` override test paths. These overrides must not be exposed to untrusted users in a privileged production boot service.

The helper only pins a symlink. It does **not** mount the runtime into an isolated user environment, verify Veyra host signatures, or install glibc compatibility libraries.
