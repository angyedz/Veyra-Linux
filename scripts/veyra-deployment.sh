#!/bin/sh
# Experimental Btrfs deployment *staging* primitive for the installed
# Plasma edition. NO bootloader changes, formatting or live root mutations.
# Requires a separately mounted Btrfs top level (subvolid=5), NEVER '/'.
set -eu

die() { echo "veyra-deployment: $*" >&2; exit 1; }
usage() {
    echo 'usage: veyra-deployment.sh init TOP | stage TOP SOURCE-ID NEW-ID | verify TOP ID' >&2
    exit 2
}
id_ok() {
    printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' &&
        [ "$1" != . ] && [ "$1" != .. ]
}
no_symlinks() {
    path=$1
    while [ "$path" != / ]; do
        [ ! -L "$path" ] || die "symlinked path is forbidden: $path"
        path=$(dirname "$path")
    done
}
top_ok() {
    case "$top" in
        /*) : ;;
        *) die 'top-level Btrfs mount must be an absolute path' ;;
    esac
    [ "$top" != / ] || die 'refusing to operate on /'
    [ -d "$top" ] || die 'missing Btrfs top-level mount'
    no_symlinks "$top"
    mountpoint -q "$top" || die 'top-level must be a dedicated mountpoint'
    fstype=$(findmnt -n -o FSTYPE -M "$top") || die 'cannot inspect target mount'
    fsroot=$(findmnt -n -o FSROOT -M "$top") || die 'cannot inspect root subvolume'
    [ "$fstype" = btrfs ] || die "expected Btrfs, found $fstype"
    [ "$fsroot" = / ] || die "expected subvolid=5, found Btrfs subvolume $fsroot"
}
marker_ok() {
    [ ! -L "$top/.veyra-deployment-store" ] || die 'symlinked store marker'
    [ -f "$top/.veyra-deployment-store" ] || die 'missing Veyra deployment store marker'
    [ "$(cat "$top/.veyra-deployment-store")" = VEYRA-DEPLOYMENT-STORE-v1 ] ||
        die 'unrecognized deployment store marker'
}
slot_path() {
    id_ok "$1" || die "invalid deployment ID: $1"
    printf '%s/@deploy-%s\n' "$top" "$1"
}
verify_slot() {
    requested=$1
    subvol=$(slot_path "$requested")
    if [ ! -d "$subvol" ] || [ -L "$subvol" ]; then
        die "missing real deployment subvolume: $requested"
    fi
    btrfs subvolume show "$subvol" >/dev/null ||
        die "deployment is not a Btrfs subvolume: $requested"
    if [ -L "$subvol/etc" ] || [ -L "$subvol/etc/veyra" ]; then
        die 'symlinked deployment metadata directory'
    fi
    [ ! -L "$subvol/etc/veyra/deployment-id" ] ||
        die 'symlinked deployment ID'
    if [ ! -f "$subvol/etc/apk/world" ] || [ -L "$subvol/etc/apk/world" ]; then
        die 'deployment needs its own regular APK world database'
    fi
    [ -f "$subvol/etc/veyra/deployment-id" ] ||
        die 'deployment ID metadata is missing'
    [ "$(cat "$subvol/etc/veyra/deployment-id")" = "$requested" ] ||
        die 'deployment ID does not match root filesystem'
}

[ "$(id -u)" -eq 0 ] || die 'requires root on a disposable/test Btrfs mount'
[ "$#" -ge 2 ] || usage
action=$1
top=$2
case "$top" in
    */) top=${top%/} ;;
esac
top_ok
case "$action" in
    init)
        [ "$#" -eq 2 ] || usage
        if [ -e "$top/.veyra-deployment-store" ] ||
           [ -L "$top/.veyra-deployment-store" ]; then
            marker_ok
        else
            (set -C; printf '%s\n' VEYRA-DEPLOYMENT-STORE-v1 > "$top/.veyra-deployment-store") ||
                die 'could not create deployment store marker'
        fi
        # User data and shared state belong to independent subvolumes.
        # This does not mount them into a running system or update fstab.
        for shared in @home @nix @shared @boot; do
            dir="$top/$shared"
            if [ -e "$dir" ] || [ -L "$dir" ]; then
                [ ! -L "$dir" ] || die "symlinked persistent subvolume: $shared"
                btrfs subvolume show "$dir" >/dev/null ||
                    die "persistent path is not a subvolume: $shared"
            else
                btrfs subvolume create "$dir"
            fi
        done
        echo 'Veyra Btrfs deployment store initialized (no boot configuration changed)'
        ;;
    verify)
        [ "$#" -eq 3 ] || usage
        marker_ok
        verify_slot "$3"
        printf 'Verified Veyra deployment: %s\n' "$3"
        ;;
    stage)
        [ "$#" -eq 4 ] || usage
        marker_ok
        src_id=$3
        dst_id=$4
        if ! id_ok "$src_id" || ! id_ok "$dst_id"; then
            die 'invalid deployment ID'
        fi
        [ "$src_id" != "$dst_id" ] || die 'cannot snapshot a deployment onto itself'
        verify_slot "$src_id"
        src=$(slot_path "$src_id")
        dst=$(slot_path "$dst_id")
        if [ -e "$dst" ] || [ -L "$dst" ]; then
            die 'refusing to overwrite an existing deployment'
        fi
        # The source is trusted and quiescent. The resulting Btrfs snapshot
        # is a NEW independently addressable deployment with its own APK DB.
        # Caller must next modify only the inactive tree, validate it,
        # then arrange an authenticated bootloader transaction.
        btrfs subvolume snapshot "$src" "$dst"
        if [ -L "$dst/etc" ] || [ -L "$dst/etc/veyra" ]; then
            die 'unsafe metadata directory in staged deployment'
        fi
        mkdir -p "$dst/etc/veyra"
        [ ! -L "$dst/etc/veyra/deployment-id" ] ||
            die 'unsafe staged deployment ID'
        printf '%s\n' "$dst_id" > "$dst/etc/veyra/deployment-id"
        verify_slot "$dst_id"
        printf 'Staged inactive Veyra deployment %s from %s; boot selection unchanged\n' "$dst_id" "$src_id"
        ;;
    *) usage ;;
esac
