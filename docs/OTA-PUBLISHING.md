# Maintainer workflow: Veyra OTA release bundles

**Status:** developer tooling and verification, **not** a deployed OTA channel or a
qualified Pre-Alpha release. Do not publish a public release until every
Pre-Alpha acceptance gate in [ROADMAP.md](ROADMAP.md) passes.

## What is actually updated?

The Live/installation **ISO is not an OTA image**. Veyra's existing
`veyra-atomic-update` uses a *signed paired-release manifest* plus
signed APK repositories to prepare **two compatible inactive system/user
Linux generations** and arm an A/B trial. The previous confirmed pair must
remain bootable until the trial passes. Treating a new ISO as an in-place
filesystem update would bypass the required isolation, package database,
persistence and rollback rules.

The bundle generator makes the maintainer side less error-prone: it
authenticates the paired manifest with the exact trusted Ed25519 public key,
hashes the installer ISO, and writes upload-ready files. It never modifies
`main`, installs an update, pushes to the network, or signs an arbitrary
download for automatic execution.

## One-time setup

On a **trusted maintainer machine**, provision an Ed25519 private key in
PKCS#8 PEM format and a base64-encoded raw (32-byte) matching public key.
The private key must be a regular file with mode 0600. Keep it off the
repository, CI artifacts, ISO, and public release; back it up securely.
Configure installed Veyra and independent Recovery with the **same
authenticated public key** at
`/etc/veyra/trust/update-ed25519.pub`, and the channel URL in
`/etc/veyra/update-manifest-url`. Both deployments need the matching,
versioned, tested updater runtime. **This provisioning is not complete in the
current installer.**

The channel URL is a plain HTTPS location such as
`https://example.org/veyra/pre-alpha/manifest.json`. The updater also
requests `manifest.json.sig` from that exact directory. Hosting must
publish both matching files as one coherent release; uploading files in
place one after another is unsafe. Prefer a versioned immutable directory
and atomically switch the channel routing after verification, or an
appropriately designed atomic object-store publication.

## Each release candidate

1. Build the actual, pinned, tested x86_64 ISO and preserve its source
   commit, signed package repository indexes and manifests. Finish the
   clean QEMU installation, dual-user environment, package resolution and
   **signed paired A/B update / forced-failure rollback** release gates.
2. Prepare a `release.json` matching the documented signed paired-update
   format. Advance `sequence` monotonically for the channel. Pin exact
   available package constraints/versions in both APK worlds and their
   reciprocal compatibility IDs. Each new generation ID must be unique.
3. Generate a local bundle in one command from the `update` directory:

   ```sh
   go run ./cmd/veyra-ota-bundle \
      --iso /absolute/path/veyra-linux-pre-alpha.iso \
      --manifest /absolute/path/release.json \
      --signing-key /secure/path/veyra-update-private.pem \
      --public-key /secure/path/veyra-update-public.pub \
      --out /absolute/path/veyra-release-bundle
   ```

4. The tool creates `manifest.json`, `manifest.json.sig`,
   `release-info.json`, `iso.sha256`, `iso.sha512` and
   `README.txt`. The private key is never copied to the bundle.
   It refuses existing output directories and mismatched/invalid keys.
5. **Only after release qualification**, publish the installer ISO as an
   immutable download for fresh installs and expose the verified
   `manifest.json` and `manifest.json.sig` on the configured
   authenticated HTTPS channel. Publication of the manifest must happen
   *after* all APK artifacts are signed and available; the channel
   should not expose a partial release. Archive the exact bytes and
   checksums. Do not replace previously published generation artifacts.

## What users will do

The intended user experience is: see "Veyra update available",
choose "Update", reboot once into the independent Recovery update
environment, and automatically return to the new confirmed desktop or
previous pair if the trial fails. This **is not implemented end-to-end**:
the current updater has a read-only `--check` and a Recovery-only
`--offline` command, and the Recovery menu currently asks for the
offline store partition and explicit UPDATE confirmation. No supported
one-click frontend, signed installed channel, automatic Recovery boot
or verified production updater exists yet. Do not advertise a live OTA
service before completing and testing those pieces.

## Security/reliability rules

- The **ISO checksum in release-info.json is informational** and does
  not authenticate an A/B package update. Only the signed paired manifest
  and repository APK signatures authorize actual update contents.
- The `manifest.json.sig` is a detached Ed25519 signature of the **exact**
  manifest bytes. Do not pretty-print, normalize or rewrite the JSON after
  signing.
- Never commit/update private signing keys; never fetch executable scripts
  or trust a public key bundled with an untrusted remote manifest.
- An operator must not publish a sequence lower than or equal to the last
  confirmed channel sequence, or reuse existing generation IDs.
- Do not copy an ISO into the deployed system root or overwrite the active
  generation. Failed updates must preserve the last confirmed system/user
  pair and personal data.
- The bundle generator by itself does not prove anti-rollback, mirror
  atomicity, target hardware health, A/B transaction safety or GUI readiness.
