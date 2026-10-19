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

absolute "$store" || fail 'store must be absolute'
absolute "$selected" || fail 'selected path must be absolute'
absolute "$runtime" || fail 'runtime mountpoint must be absolute'
[ -L "$selected" ] || fail "no verified boot-pinned selector: $selected"
[ -d "$store" ] && [ ! -L "$store" ] || fail "invalid store root: $store"
[ -d "$store/versions" ] && [ ! -L "$store/versions" ] || fail 'versions directory is not real'

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
[ -d "$source" ] && [ ! -L "$source" ] || fail "invalid release directory: $source"
[ -f "$source/glenv-manifest.json" ] || fail 'release has no verified inventory'
case "$runtime" in
    "$store"|"$store"/*) fail 'runtime mountpoint overlaps the store' ;;
esac
[ ! -L "$runtime" ] || fail 'runtime mountpoint is a symlink'
[ ! -e "$runtime" ] || [ -d "$runtime" ] || fail 'runtime mountpoint is not a directory'

if [ -n "$userroot" ]; then
    absolute "$userroot" || fail 'user environment root must be absolute'
    [ -d "$userroot" ] && [ ! -L "$userroot" ] || fail 'user environment root must be a real directory'
    case "$userroot" in
        /|"$store"|"$store"/*) fail 'unsafe user environment root' ;;
    esac
    # Reject redirection of mountpoints through user-environment symlinks.
    for candidate in "$userroot/run" "$userroot/run/glenv" "$userroot/run/glenv/runtime"; do
        [ ! -L "$candidate" ] || fail "symlinked user mountpoint component: $candidate"
    done
fi

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
