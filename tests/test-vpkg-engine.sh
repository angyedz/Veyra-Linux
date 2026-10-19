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
mkdir -p "$root/etc/apk/keys" "$root/etc/apk" "$root/lib/apk/db" "$root/var/cache/apk"
cp /etc/apk/keys/*.pub "$root/etc/apk/keys/"
# apk-tools 2.14 requires a preinitialized world + installed database for
# ordinary add operations; creating them is safe in this disposable root.
: > "$root/etc/apk/world"
: > "$root/lib/apk/db/installed"
cat > "$root/etc/apk/repositories" <<'REPOS'
https://dl-cdn.alpinelinux.org/alpine/v3.22/main
https://dl-cdn.alpinelinux.org/alpine/v3.22/community
REPOS
# All writes go to a fresh disposable target. Signatures are REQUIRED:
# --allow-untrusted is deliberately not used.
if ! strace -f -e trace=file -o "$tmp/vpkg.trace" \
    "$engine" --root "$root" --no-cache add busybox; then
    echo 'vpkg file access failures (disposable test root):' >&2
    grep 'ENOENT' "$tmp/vpkg.trace" | tail -35 >&2 || true
    exit 1
fi
"$engine" --root "$root" info -e busybox
test -x "$root/bin/busybox"
test -s "$root/lib/apk/db/installed"
test -s "$root/etc/apk/world"
# The engine must not replace or rename the host APK.
command -v apk
apk --version
echo 'Patched vpkg-engine installed a signed APK only in disposable target root'
