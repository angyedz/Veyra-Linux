# Veyra first-party APK packages

The authoritative APKBUILD recipes, application sources, signed binary
repository and automated release workflow live in
https://github.com/angyedz/veyra-pkgrepo.

This distribution repository owns only the Go implementation of vpkg,
installer, image generation, and integration tests.

The packages/build.sh script is a manual emergency compatibility wrapper:
it requires a checkout of veyra-pkgrepo at pkgrepo-source/ and builds
from that repository's scripts/build.sh, never from distro-side APKBUILDs.
The old distro workflow is manual-only so it does not race the canonical
publisher. It may continue using the existing distro signing secrets while
the persistent signing key is securely configured in veyra-pkgrepo.

The new package workflow in veyra-pkgrepo requires the existing private
abuild key in its VEYRA_ABUILD_PRIVATE_KEY_B64 secret to publish a trusted
stable snapshot. Unconfigured builds produce CI artifacts only.
Do not commit any signing secret or bypass APK signature checks.
