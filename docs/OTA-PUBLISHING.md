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

The bundle generator and independent verifier make the maintainer side less error-prone: they
authenticates the paired manifest with the exact trusted Ed25519 public key,
hashes the installer ISO, and writes upload-ready files. It never modifies
`main`, installs an update, pushes to the network, or signs an arbitrary
download for automatic execution.

## One-time setup

On a **trusted maintainer machine**, generate a new Ed25519 signing identity
with a single command from the `update` directory:

```sh
go run ./cmd/veyra-ota-keygen --out /absolute/private/veyra-keys
```

The generated files are `veyra-update-private.pem` (PKCS#8, mode 0600)
and `veyra-update-public.pub` (base64-encoded 32-byte Ed25519 public key).
The new directory is created with mode 0700. Never reuse or overwrite an
existing signing key directory.
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
   `release-info.json`, `release-info.json.sig`, `iso.sha256`, `iso.sha512` and
   `README.txt`. The private key is never copied to the bundle.
   It refuses existing output directories and mismatched/invalid keys.
5. Verify the complete upload bundle **without access to the private key**:

   ```sh
   go run ./cmd/veyra-ota-bundle \
      --verify-bundle /absolute/path/veyra-release-bundle \
      --iso /absolute/path/veyra-linux-pre-alpha.iso \
      --public-key /secure/path/veyra-update-public.pub
   ```

   The verifier checks **both detached signatures**, paired system/user
   compatibility, signed ISO SHA-256/SHA-512, and the published checksum
   files. This is suitable for a future CI publication gate.

6. **Only after release qualification**, publish the installer ISO as an
   immutable download for fresh installs and expose the verified
   `manifest.json` and `manifest.json.sig` on the configured
   authenticated HTTPS channel. Publication of the manifest must happen
   *after* all APK artifacts are signed and available; the channel
   should not expose a partial release. Archive the exact bytes and
   checksums. Do not replace previously published generation artifacts.

## GitHub automatic channel promotion (opt-in, NOT enabled)

The repository also contains \`.github/workflows/ota-channel.yml\`.
Once the real Pre-Alpha is qualified, a maintainer can configure a
protected GitHub Actions environment named \`veyra-prealpha-ota\`
(reviewer approval recommended), add the **public** Ed25519 trust key at
\`.github/trust/veyra-ota-ed25519.pub\`, and set repository variable
\`VEYRA_OTA_PUBLISH_ENABLED=true\`. **Do not enable this now.** A
manually enabled variable is not a substitute for the release gates.

The intended final maintainer workflow will then be:

1. Produce the ISO and signed metadata using the offline bundle command,
   and independently verify them.
2. Create a GitHub **Draft Release** whose tag exactly equals the signed
   manifest \`release\` field and points to the qualified \`main\` commit.
   Upload the installer \`.iso\` and the **six** release bundle files:
   \`manifest.json\`, \`manifest.json.sig\`, \`release-info.json\`,
   \`release-info.json.sig\`, \`iso.sha256\`, \`iso.sha512\`. Never upload
   the signing private key.
3. After human review of every Pre-Alpha gate, publish the draft Release.
   GitHub Actions requires successful integration, ISO and independent
   Recovery workflows **for that exact commit**, downloads the release
   assets, verifies both Ed25519 signatures, ISO hashes and release tag,
   and rejects a repeated or lower signed sequence.
4. Only then does the workflow commit the matching manifest and signature
   **together** to the \`ota-channel\` Git branch. Its public HTTPS
   \`pre-alpha/manifest.json\` path is the channel pointer used by
   \`veyra-atomic-update\`. Git ref promotion is atomic; caches may
   temporarily serve a mismatched pair, which the signature verifier must
   reject rather than install. The ISO stays as a GitHub Release download.

Example update-channel URL **after configuration**:

\`https://raw.githubusercontent.com/angyedz/Veyra-Linux/ota-channel/pre-alpha/manifest.json\`

A pinned public trust key, qualified dual environment, installed channel
configuration, trustworthy updater/Recovery and signed APK availability
remain mandatory. The publish workflow does not automatically invent
versions or build an ISO from its manifest and does not grant a pass on
unverified release behavior.

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

- The ISO checksum in `release-info.json` is **signed** by the release key,
  binding the ISO bytes to the maintainer metadata. It does **not** authorize
  an A/B package update: only the signed paired manifest and APK repository
  signatures authorize the installed update contents.
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
