#!/bin/sh
# Verify that an ISO manifest matches the ISO bytes, package index and source metadata.
set -eu

iso=${1:?usage: sh scripts/verify-iso-manifest.sh ISO MANIFEST}
manifest=${2:?usage: sh scripts/verify-iso-manifest.sh ISO MANIFEST}
[ -f "$iso" ] || { echo "ISO not found: $iso" >&2; exit 1; }
[ -f "$manifest" ] || { echo "Manifest not found: $manifest" >&2; exit 1; }

field() {
    awk -F= -v wanted="$1" '
        $1 == wanted {
            if (++matches > 1) exit 1
            value = substr($0, length(wanted) + 2)
        }
        END {
            if (matches != 1) exit 1
            print value
        }
    ' "$manifest"
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
expected="$tmpdir/expected.manifest"
VEYRA_SOURCE_COMMIT="$(field veyra_source_commit)" \
VEYRA_APORTS_REVISION="$(field alpine_aports_commit)" \
VEYRA_APPCENTER_REVISION="$(field appcenter_source_commit)" \
VEYRA_UPDATE_REVISION="$(field veyra_update_source_commit)" \
VEYRA_GLENV_REVISION="$(field glenv_source_commit)" \
VEYRA_VERSION="$(field veyra_version)" \
VEYRA_ALPINE_VERSION="$(field alpine_release)" \
VEYRA_ARCH="$(field architecture)" \
    sh "$(dirname "$0")/write-iso-manifest.sh" "$iso" "$expected"

expected_hash=$(sha256sum "$expected" | awk '{print $1}')
manifest_hash=$(sha256sum "$manifest" | awk '{print $1}')
if [ "$expected_hash" != "$manifest_hash" ]; then
    echo 'ISO source/package manifest does not match the image contents or metadata' >&2
    exit 1
fi
echo "ISO source/package manifest verified: $manifest"
