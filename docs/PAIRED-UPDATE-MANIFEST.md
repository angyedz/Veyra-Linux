# Signed paired-update manifest

**Status:** verifier prototype. This format does not yet download packages,
stage roots, activate GRUB or replace the current in-place `veyra-update`.

The exact release JSON bytes are authenticated by a detached Ed25519 signature.
The JSON identifies both root generations, their explicit APK package worlds,
the repositories to use and reciprocal compatibility IDs. The system and user
APK repositories continue to authenticate APK indexes and package archives
with their existing APK signing keys.

## Format

`format` is `veyra-pair-release-v1`; `sequence` is a positive monotonically
increasing channel number; the initial supported `architecture` is `x86_64`.
`system` and `user` each contain:

- `id`: the generation identifier to stage;
- `provides`: the compatibility ID this root exports;
- `requires_other`: the compatibility ID required from the paired root;
- `repositories`: one or more objects with an HTTPS `url` and an optional APK
  repository `tag` (written as `@tag URL` in the staged root's repositories file);
- `world`: the APK package constraints that define the root's explicit package
  selection;
- `required_packages`: package name to exact version pairs that every staged
  root must contain.

The verifier requires reciprocal compatibility (`system.requires_other` must
match `user.provides`, and vice versa), unique APK constraints and repositories,
and rejects unknown fields, malformed package specs and non-HTTPS repositories.
Signatures cover the exact JSON bytes; release tooling must not reformat the
document after signing. The public key is 32 raw Ed25519 bytes or base64 of
those bytes. The detached signature is 64 raw bytes or base64 of those bytes.

The update library also provides the user-world merge policy for the future
stager: signed release constraints take precedence for packages owned by the
release, while additional APK packages already selected by the user remain in
their existing order. This policy is not yet connected to an installed updater.

Example shape (the values are illustrative and unsigned):

```json
{
  "format": "veyra-pair-release-v1",
  "release": "pre-alpha-0.1.0-rc1",
  "sequence": 1,
  "architecture": "x86_64",
  "system": {
    "id": "S-2026-10-23",
    "provides": "system-api-v1",
    "requires_other": "user-api-v1",
    "repositories": [{"url": "https://packages.example.invalid/stable/system"}],
    "world": ["alpine-base=3.22.0-r1", "linux-lts=6.12.20-r0"],
    "required_packages": {"alpine-base": "3.22.0-r1", "linux-lts": "6.12.20-r0"}
  },
  "user": {
    "id": "U-2026-10-23",
    "provides": "user-api-v1",
    "requires_other": "system-api-v1",
    "repositories": [{"url": "https://packages.example.invalid/stable/user", "tag": "veyra"}],
    "world": ["alpine-base=3.22.0-r1", "vpkg=0.1.0-r1"],
    "required_packages": {"alpine-base": "3.22.0-r1", "vpkg": "0.1.0-r1"}
  }
}
```

## Verification

Build with `go build ./cmd/veyra-update-verify` from `update/`, then run:

```sh
veyra-update-verify \
  --manifest veyra-release.json \
  --signature veyra-release.json.sig \
  --public-key /etc/veyra/trust/update-ed25519.pub
```

The command prints a compact JSON summary only after signature and schema checks
pass. The current tool accepts an explicit public-key path for CI and release
inspection. An installed updater must instead use a root-owned trust key fixed
by system configuration, verify package signatures, verify staged package
databases and boot artifacts, persist the highest confirmed sequence to reject
replayed older releases, and stage only inactive roots before it may arm a
trial. Those transaction and trust-store checks are still required before
Pre-Alpha.
