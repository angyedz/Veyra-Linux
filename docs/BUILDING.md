# Building Veyra Linux

The ISO pipeline uses Alpine Linux's `aports/scripts/mkimage.sh` and a custom image profile in `images/mkimg.veyra.sh`.

## Automated build

Pushes to `main` that change the image configuration trigger the **Veyra ISO** workflow. Its successful run publishes an ISO and checksums as a workflow artifact. This is a development image, not a tested stable release.

## Local build

Use a **disposable Alpine 3.22 x86_64 environment** with network access and adequate free disk space.

```sh
git clone https://github.com/angyedz/Veyra-Linux.git
cd Veyra-Linux
sh scripts/build-iso.sh  # root required
```

The resulting files will appear in `dist/`. The build script installs tooling, downloads a matching Alpine aports tree, creates an ephemeral signing key and invokes mkimage. The generated signing key is for development only; a reproducible release process needs a securely managed persistent release key.

The ISO contains a small Alpine-based live environment, an on-image `veyra-setup` helper, and the native Nix package. The glenv subsystem is installed separately using its upstream installer when `veyra-setup` is run; it is **not baked into the ISO**.

## Validation

```sh
sh tests/static.sh
sh scripts/smoke.sh
```

The static checks validate shell scripts, image profile and overlay contents. The smoke test must run **inside an Alpine system where components have already been installed**. GitHub CI also runs ShellCheck and verifies the Alpine Nix package is installable.

GitHub Actions boots each built image under QEMU and looks for a serial-console login banner. This verifies a basic boot path, not a full installation. Graphical installation and long-running application tests are not yet automated.
