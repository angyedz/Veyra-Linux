#!/bin/sh
# Smoke test the patched APK-derived Veyra engine without changing the host.
set -eu
project=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
engine="$project/dist/vpkg-engine/vpkg-engine"
[ -x "$engine" ] || { echo 'Missing compiled vpkg engine' >&2; exit 1; }
"$engine" --version | grep -q 'Veyra vpkg engine'
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
root="$tmp/target"
mkdir -p "$root/etc/apk/keys" "$root/etc/apk" "$root/lib/apk/db"
cp /etc/apk/keys/*.pub "$root/etc/apk/keys/"
cat > "$root/etc/apk/repositories" <<'REPOS'
https://dl-cdn.alpinelinux.org/alpine/v3.22/main
https://dl-cdn.alpinelinux.org/alpine/v3.22/community
REPOS
# All writes go to a fresh disposable target. Signatures are REQUIRED:
# --allow-untrusted is deliberately not used.
"$engine" --root "$root" --initdb --no-cache add busybox
"$engine" --root "$root" info -e busybox
test -x "$root/bin/busybox"
test -s "$root/lib/apk/db/installed"
test -s "$root/etc/apk/world"
# The engine must not replace or rename the host APK.
command -v apk
apk --version
echo 'Patched vpkg-engine installed a signed APK only in disposable target root'
