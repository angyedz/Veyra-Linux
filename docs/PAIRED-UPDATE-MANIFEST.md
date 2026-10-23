# Signed paired-update manifest

**Status:** experimental signed paired-updater source exists, but it is not
packaged or usable in the current ISO. Applying requires the independent Veyra
Recovery Environment (VRE); the current VRE contains only diagnostics and does
not bundle this updater, its channel configuration or its trusted update key.
The installed `veyra-update` package still performs in-place APK upgrades.
Do not describe this prototype as a working update path.

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

The update library provides the user-world merge policy used by the experimental
paired stager: signed release constraints take precedence for packages owned by
the release, while additional APK packages already selected by the user remain
in their existing order. The stager and its policy are not integrated into the
installed package or recovery image.

`veyra-atomic-update --check` verifies the configured HTTPS release online.
Applying requires root, `--offline`, and the exact VRE marker under `/run`; it
also refuses targets that share the recovery root filesystem or contain any
mounted filesystem. These checks are fail-closed groundwork, not proof of a
secure or end-to-end usable VRE update flow.

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

Build with `go build ./cmd/veyra-update-verify` and
`go build ./cmd/veyra-atomic-update` from `update/`, then run the verifier:

```sh
veyra-update-verify \
  --manifest veyra-release.json \
  --signature veyra-release.json.sig \
  --public-key /etc/veyra/trust/update-ed25519.pub
```

The verifier prints a compact JSON summary only after signature and schema
checks pass. It accepts an explicit public-key path for CI and release
inspection. The updater CLI reads a root-owned key and channel URL from system
configuration, but that configuration is not provisioned in the current VRE.
Package signatures, staged package databases, boot artifacts, independent
highest-confirmed-sequence storage, durable transactions, VRE provisioning and
the signed pair's QEMU trial/fallback path still require end-to-end validation
before Pre-Alpha.
