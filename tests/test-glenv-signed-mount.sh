#!/bin/sh
# Called ONLY by CI from a fresh privileged Linux mount namespace.
# Mounts a signed runtime at separate host/user paths without touching disks.
set -eu

[ "$(id -u)" -eq 0 ] || { echo 'Signed mount test requires root' >&2; exit 1; }
[ "${VEYRA_GLENV_REQUIRE_SIGNATURE:-0}" = 1 ] || {
    echo 'Signed mount test must not run in unsigned mode' >&2
    exit 1
}
: "${VEYRA_GLENV_RUNTIME_MOUNT:?}"
: "${VEYRA_GLENV_USER_ROOT:?}"
: "${VEYRA_GLENV_BIN:?}"
: "${VEYRA_GLENV_TRUST_KEY:?}"

host=$VEYRA_GLENV_RUNTIME_MOUNT
user=$VEYRA_GLENV_USER_ROOT/run/glenv/runtime

cleanup() {
    if mountpoint -q "$user" 2>/dev/null; then umount "$user" || true; fi
    if mountpoint -q "$host" 2>/dev/null; then umount "$host" || true; fi
}
trap cleanup 0
trap 'exit 1' 1 2 3 15

sh scripts/glenv-boot-mount.sh --check
sh scripts/glenv-boot-mount.sh

mountpoint -q "$host" || { echo 'Missing signed host mount' >&2; exit 1; }
mountpoint -q "$user" || { echo 'Missing signed user mount' >&2; exit 1; }
cmp -s "$host/glenv-manifest.json" "$user/glenv-manifest.json"
cmp -s "$host/glenv-manifest.json.sig" "$user/glenv-manifest.json.sig"

"$VEYRA_GLENV_BIN" release verify-signed "$host" "$VEYRA_GLENV_TRUST_KEY"
"$VEYRA_GLENV_BIN" release verify-signed "$user" "$VEYRA_GLENV_TRUST_KEY"

if touch "$host/should-not-write" 2>/dev/null; then
    echo 'Signed host glenv runtime is writable' >&2
    exit 1
fi
if touch "$user/should-not-write" 2>/dev/null; then
    echo 'Signed user glenv runtime is writable' >&2
    exit 1
fi
echo 'Signed glenv host/user read-only mount test passed'
