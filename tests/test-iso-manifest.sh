#!/bin/sh
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/index"

cat > "$tmp/index/APKINDEX" <<'INDEX'
C:Q1example
P:alpine-base
V:3.22.0-r0
A:x86_64

C:Q2example
P:veyra-calamares
V:1.0.0-r2
A:x86_64

C:Q3example
P:veyra-update
V:0.1.0-r2
A:x86_64
INDEX
tar -czf "$tmp/APKINDEX.tar.gz" -C "$tmp/index" APKINDEX
cat > "$tmp/bin/xorriso" <<'XORRISO'
#!/bin/sh
set -eu
iso_path=
destination=
while [ "$#" -gt 0 ]; do
    if [ "$1" = -extract ]; then
        shift
        iso_path=${1:?missing ISO path}
        shift
        destination=${1:?missing extraction target}
    fi
    shift
done
[ "$iso_path" = /apks/x86_64/APKINDEX.tar.gz ] || exit 2
cp "$VEYRA_TEST_APKINDEX" "$destination"
XORRISO
chmod +x "$tmp/bin/xorriso"
touch "$tmp/veyra-linux-test.iso"

source_commit=0123456789abcdef0123456789abcdef01234567
aports_commit=123456789abcdef0123456789abcdef012345678
appcenter_commit=23456789abcdef0123456789abcdef0123456789
glenv_commit=3456789abcdef0123456789abcdef01234567890
update_commit=456789abcdef0123456789abcdef0123456789ab
PATH="$tmp/bin:$PATH" \
VEYRA_TEST_APKINDEX="$tmp/APKINDEX.tar.gz" \
VEYRA_SOURCE_COMMIT="$source_commit" \
VEYRA_APORTS_REVISION="$aports_commit" \
VEYRA_APPCENTER_REVISION="$appcenter_commit" \
VEYRA_UPDATE_REVISION="$update_commit" \
VEYRA_GLENV_REVISION="$glenv_commit" \
VEYRA_VERSION=0.1.0-alpha.1+test \
VEYRA_ALPINE_VERSION=3.22 \
sh "$root/scripts/write-iso-manifest.sh" "$tmp/veyra-linux-test.iso" "$tmp/manifest.txt"

grep -qx 'format=veyra-iso-manifest-v2' "$tmp/manifest.txt"
grep -qx "veyra_source_commit=$source_commit" "$tmp/manifest.txt"
grep -qx "alpine_aports_commit=$aports_commit" "$tmp/manifest.txt"
grep -qx "appcenter_source_commit=$appcenter_commit" "$tmp/manifest.txt"
grep -qx "veyra_update_source_commit=$update_commit" "$tmp/manifest.txt"
grep -qx "glenv_source_commit=$glenv_commit" "$tmp/manifest.txt"
grep -qx 'package_count=3' "$tmp/manifest.txt"
grep -Fqx "$(printf 'alpine-base\t3.22.0-r0')" "$tmp/manifest.txt"
grep -Fqx "$(printf 'veyra-calamares\t1.0.0-r2')" "$tmp/manifest.txt"
grep -Fqx "$(printf 'veyra-update\t0.1.0-r2')" "$tmp/manifest.txt"
PATH="$tmp/bin:$PATH" VEYRA_TEST_APKINDEX="$tmp/APKINDEX.tar.gz" \
    VEYRA_SOURCE_COMMIT="$source_commit" \
    VEYRA_APORTS_REVISION="$aports_commit" \
    VEYRA_APPCENTER_REVISION="$appcenter_commit" \
    VEYRA_GLENV_REVISION="$glenv_commit" \
    VEYRA_VERSION=0.1.0-alpha.1+test VEYRA_ALPINE_VERSION=3.22 \
    sh "$root/scripts/verify-iso-manifest.sh" "$tmp/veyra-linux-test.iso" "$tmp/manifest.txt"
awk 'index($0, "veyra-calamares\t") == 1 { print "veyra-calamares\t9.9.9-r9"; next } { print }' \
    "$tmp/manifest.txt" > "$tmp/tampered.txt"
if PATH="$tmp/bin:$PATH" VEYRA_TEST_APKINDEX="$tmp/APKINDEX.tar.gz" \
    VEYRA_SOURCE_COMMIT="$source_commit" \
    VEYRA_APORTS_REVISION="$aports_commit" \
    VEYRA_APPCENTER_REVISION="$appcenter_commit" \
    VEYRA_GLENV_REVISION="$glenv_commit" \
    VEYRA_VERSION=0.1.0-alpha.1+test VEYRA_ALPINE_VERSION=3.22 \
    sh "$root/scripts/verify-iso-manifest.sh" "$tmp/veyra-linux-test.iso" "$tmp/tampered.txt"; then
    echo 'Manifest verifier accepted a changed package version' >&2
    exit 1
fi

if PATH="$tmp/bin:$PATH" VEYRA_TEST_APKINDEX="$tmp/missing-index.tar.gz" \
    sh "$root/scripts/write-iso-manifest.sh" "$tmp/veyra-linux-test.iso" "$tmp/missing.txt"; then
    echo 'Manifest writer accepted a missing embedded APK index' >&2
    exit 1
fi

echo 'ISO source/package manifest tests passed'
