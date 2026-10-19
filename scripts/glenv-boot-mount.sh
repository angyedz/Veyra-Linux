#!/bin/sh
# Opt-in, early-boot read-only glenv mount. Not enabled in any OpenRC runlevel.
# Invoke only in a disposable test guest until Veyra's signed boot coordinator
# and immutable glenv store are implemented.
set -eu

mode=${1:-}
case "$mode" in
    ''|--check) ;;
    *) echo 'usage: sh scripts/glenv-boot-mount.sh [--check]' >&2; exit 2 ;;
esac

store=${VEYRA_GLENV_STORE:-/var/lib/veyra/glenv}
selected=${VEYRA_GLENV_SELECTED:-/run/glenv/selected}
runtime=${VEYRA_GLENV_RUNTIME_MOUNT:-/run/glenv/runtime}
userroot=${VEYRA_GLENV_USER_ROOT:-}

fail() { echo "glenv boot mount: $*" >&2; exit 1; }
absolute() { case "$1" in /*) return 0;; *) return 1;; esac; }
no_symlink_components() {
    component=$1
    while [ "$component" != / ]; do
        [ ! -L "$component" ] || fail "symlinked mount path component: $component"
        component=$(dirname "$component")
    done
}

absolute "$store" || fail 'store must be absolute'
absolute "$selected" || fail 'selected path must be absolute'
absolute "$runtime" || fail 'runtime mountpoint must be absolute'
[ -L "$selected" ] || fail "no verified boot-pinned selector: $selected"
if [ ! -d "$store" ] || [ -L "$store" ]; then fail "invalid store root: $store"; fi
if [ ! -d "$store/versions" ] || [ -L "$store/versions" ]; then fail 'versions directory is not real'; fi

# The pin was produced by glenv boot-pair-pin, which verified the release.
# Check path containment a second time before any privileged mount. Caller
# must prevent concurrent tampering with the trusted store.
versions=$(readlink -f "$store/versions") || fail 'cannot resolve version store'
source=$(readlink -f "$selected") || fail 'cannot resolve selected generation'
case "$source" in
    "$versions"/*) ;;
    *) fail "selector escapes trusted version store: $source" ;;
esac
[ "$(dirname "$source")" = "$versions" ] || fail 'selector must name one release directory'
if [ ! -d "$source" ] || [ -L "$source" ]; then fail "invalid release directory: $source"; fi
[ -f "$source/glenv-manifest.json" ] || fail 'release has no verified inventory'
case "$runtime" in
    "$store"|"$store"/*) fail 'runtime mountpoint overlaps the store' ;;
esac
no_symlink_components "$runtime"
[ ! -e "$runtime" ] || [ -d "$runtime" ] || fail 'runtime mountpoint is not a directory'

if [ -n "$userroot" ]; then
    absolute "$userroot" || fail 'user environment root must be absolute'
    if [ ! -d "$userroot" ] || [ -L "$userroot" ]; then fail 'user environment root must be a real directory'; fi
    case "$userroot" in
        /|"$store"|"$store"/*|"$runtime"|"$runtime"/*) fail 'unsafe user environment root' ;;
    esac
    no_symlink_components "$userroot"
    # Reject redirection of mountpoints through user-environment symlinks.
    for candidate in "$userroot/run" "$userroot/run/glenv" "$userroot/run/glenv/runtime"; do
        [ ! -L "$candidate" ] || fail "symlinked user mountpoint component: $candidate"
    done
fi

# Signed deployments must be re-verified against the externally trusted
# host key immediately before mounting. Never treat a pin symlink or a
# checksum-only manifest as an authenticated runtime.
case "${VEYRA_GLENV_REQUIRE_SIGNATURE:-0}" in
    0) : ;; # Legacy opt-in test mode only
    1)
        trusted_key=${VEYRA_GLENV_TRUST_KEY:-/etc/veyra/trust/glenv-ed25519.pub}
        glenv_bin=${VEYRA_GLENV_BIN:-glenv}
        absolute "$trusted_key" || fail 'trusted glenv public key path must be absolute'
        no_symlink_components "$trusted_key"
        [ -f "$trusted_key" ] || fail "trusted glenv public key is missing: $trusted_key"
        [ "$(stat -c %u "$trusted_key")" = 0 ] || fail 'trusted glenv public key must be root-owned'
        permissions=$(stat -c %a "$trusted_key")
        case "$permissions" in
            ''|*[!0-7]*) fail 'invalid trusted glenv key permissions' ;;
        esac
        [ $((0$permissions & 022)) -eq 0 ] || fail 'trusted glenv public key is writable by group/others'
        "$glenv_bin" release verify-signed "$source" "$trusted_key" ||
            fail 'signed glenv release failed pre-mount verification'
        ;;
    *) fail 'VEYRA_GLENV_REQUIRE_SIGNATURE must be 0 or 1' ;;
esac

if [ "$mode" = --check ]; then
    printf 'Validated glenv mount: %s -> %s\n' "$source" "$runtime"
    if [ -n "$userroot" ]; then
        printf 'User environment bind target: %s/run/glenv/runtime\n' "$userroot"
    fi
    exit 0
fi

[ "$(id -u)" -eq 0 ] || fail 'mounting requires root'
command -v mountpoint >/dev/null || fail 'mountpoint utility is required'
command -v mount >/dev/null || fail 'mount utility is required'
command -v umount >/dev/null || fail 'umount utility is required'

host_mounted=0
user_mounted=0
finished=0
usertarget=''
cleanup() {
    if [ "$finished" -eq 0 ]; then
        if [ "$user_mounted" -eq 1 ]; then
            umount "$usertarget" || echo 'Warning: failed to unmount user target' >&2
        fi
        if [ "$host_mounted" -eq 1 ]; then
            umount "$runtime" || echo 'Warning: failed to unmount host target' >&2
        fi
    fi
}
trap cleanup 0
trap 'exit 1' 1 2 3 15

mkdir -p "$runtime"
mountpoint -q "$runtime" && fail 'host runtime mountpoint is already mounted'
mount --bind "$source" "$runtime"
host_mounted=1
mount --make-private "$runtime"
mount -o remount,bind,ro "$runtime"

if [ -n "$userroot" ]; then
    usertarget="$userroot/run/glenv/runtime"
    mkdir -p "$usertarget"
    mountpoint -q "$usertarget" && fail 'user runtime mountpoint is already mounted'
    mount --bind "$runtime" "$usertarget"
    user_mounted=1
    mount --make-private "$usertarget"
    mount -o remount,bind,ro "$usertarget"
fi

finished=1
printf 'Read-only glenv runtime mounted for host'
[ -z "$usertarget" ] || printf ' and user environment'
printf '\n'
