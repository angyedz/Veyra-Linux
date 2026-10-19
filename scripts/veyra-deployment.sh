#!/bin/sh
# Experimental FS-neutral *offline staging* for the installed Veyra Plasma
# edition. No partition formatting, bootloader updates or root switching.
# ext4, XFS, F2FS, Btrfs and other Linux filesystems may host this store.
# ShellCheck SC2015: each A && B || die pattern deliberately rejects either failed check.
# shellcheck disable=SC2015
set -eu

die() { echo "veyra-deployment: $*" >&2; exit 1; }
usage() {
    echo 'usage: veyra-deployment.sh init STORE-MOUNT | stage STORE-MOUNT SOURCE-ID NEW-ID | verify STORE-MOUNT ID' >&2
    exit 2
}
id_ok() {
    printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' &&
        [ "$1" != . ] && [ "$1" != .. ]
}
no_symlinks() {
    candidate=$1
    while [ "$candidate" != / ]; do
        [ ! -L "$candidate" ] || die "symlink path forbidden: $candidate"
        candidate=$(dirname "$candidate")
    done
}
store_ok() {
    case "$store" in
        /*) : ;;
        *) die 'deployment store must be an absolute path' ;;
    esac
    [ "$store" != / ] || die 'refusing to operate on live /'
    [ -d "$store" ] || die 'deployment store not found'
    no_symlinks "$store"
    mountpoint -q "$store" || die 'deployment store must be its own mountpoint'
    filesystem=$(findmnt -n -o FSTYPE -M "$store") ||
        die 'cannot inspect mounted filesystem'
    [ -n "$filesystem" ] || die 'cannot detect filesystem'
    case "$filesystem" in
        proc|sysfs|devtmpfs|devpts|tmpfs|overlay|squashfs)
            die "not a persistent filesystem: $filesystem" ;;
    esac
}
marker_ok() {
    [ ! -L "$store/.veyra-deployment-store" ] || die 'symlinked store marker'
    [ -f "$store/.veyra-deployment-store" ] ||
        die 'missing Veyra deployment marker (run init)'
    [ "$(cat "$store/.veyra-deployment-store")" = VEYRA-DEPLOYMENT-STORE-v2 ] ||
        die 'invalid or obsolete Veyra deployment store format'
}
slot_path() {
    id_ok "$1" || die "invalid deployment ID: $1"
    printf '%s/deployments/%s\n' "$store" "$1"
}
verify_slot() {
    requested=$1
    slot=$(slot_path "$requested")
    [ -d "$slot" ] && [ ! -L "$slot" ] ||
        die "missing real deployment directory: $requested"
    for rel in etc etc/apk etc/veyra; do
        [ ! -L "$slot/$rel" ] ||
            die "symlinked deployment metadata: $rel"
    done
    [ -f "$slot/etc/apk/world" ] && [ ! -L "$slot/etc/apk/world" ] ||
        die "missing independent APK world database: $requested"
    [ -f "$slot/etc/veyra/deployment-id" ] &&
        [ ! -L "$slot/etc/veyra/deployment-id" ] ||
        die "missing real deployment ID file: $requested"
    [ "$(cat "$slot/etc/veyra/deployment-id")" = "$requested" ] ||
        die "deployment identity mismatch: $requested"
    for path in home nix; do
        [ ! -L "$slot/$path" ] ||
            die "symlinked persistent mount placeholder: $path"
    done
}
[ "$(id -u)" -eq 0 ] || die 'requires root and a dedicated offline deployment store'
[ "$#" -ge 2 ] || usage
action=$1
store=$2
case "$store" in */) store=${store%/} ;; esac
store_ok
case "$action" in
    init)
        [ "$#" -eq 2 ] || usage
        if [ -e "$store/.veyra-deployment-store" ] ||
           [ -L "$store/.veyra-deployment-store" ]; then
            marker_ok
        else
            # Never import or mutate an older filesystem-specific store.
            [ ! -e "$store/deployments" ] || die 'nonempty/uninitialized deployment location'
            [ ! -e "$store/persistent" ] || die 'nonempty/uninitialized persistent location'
            (set -C; printf '%s\n' VEYRA-DEPLOYMENT-STORE-v2 > "$store/.veyra-deployment-store") ||
                die 'unable to create deployment store marker'
        fi
        for dir in deployments persistent/home persistent/nix persistent/shared boot-state; do
            [ ! -L "$store/$dir" ] || die "symlinked store path: $dir"
            mkdir -p "$store/$dir"
        done
        echo "Initialized filesystem-neutral Veyra staging store on $filesystem (no boot modifications)"
        ;;
    verify)
        [ "$#" -eq 3 ] || usage
        marker_ok
        verify_slot "$3"
        echo "Verified Veyra deployment $3 on $filesystem"
        ;;
    stage)
        [ "$#" -eq 4 ] || usage
        marker_ok
        id_ok "$3" && id_ok "$4" || die 'invalid deployment ID'
        [ "$3" != "$4" ] || die 'cannot stage deployment onto itself'
        verify_slot "$3"
        source=$(slot_path "$3")
        target=$(slot_path "$4")
        temp="$store/deployments/.staging-$4"
        [ ! -e "$target" ] && [ ! -L "$target" ] ||
            die 'target deployment already exists'
        [ ! -e "$temp" ] && [ ! -L "$temp" ] ||
            die 'staging directory already exists (manual recovery required)'
        [ -x "$(command -v rsync)" ] || die 'rsync is required for safe offline root copies'
        # No snapshots, reflinks or filesystem-specific commands. Root tree
        # must be QUIESCENT: callers cannot stage from the actively changing /.
        # Never import persistent mounts, bootloader state or child filesystems.
        mkdir "$temp"
        if ! rsync -aHAX --numeric-ids --one-file-system \
            --exclude='/home/***' --exclude='/nix/***' \
            --exclude='/proc/***' --exclude='/sys/***' \
            --exclude='/dev/***' --exclude='/run/***' \
            --exclude='/tmp/***' --exclude='/mnt/***' \
            --exclude='/media/***' \
            "$source/" "$temp/"; then
            die "staging copy failed; inspect $temp before cleanup"
        fi
        [ ! -L "$temp/etc/veyra/deployment-id" ] ||
            die 'staged deployment ID symlink rejected'
        printf '%s\n' "$4" > "$temp/etc/veyra/deployment-id"
        # Verify before exposing the new ID; a rename within this mount is
        # atomic, but it is NOT a bootloader/OTA commit.
        [ -f "$temp/etc/apk/world" ] || die 'staged root missing APK world'
        mv -T "$temp" "$target"
        verify_slot "$4"
        echo "Staged inactive Veyra deployment $4 on $filesystem; boot unchanged"
        ;;
    *) usage ;;
esac
