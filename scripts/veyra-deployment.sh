#!/bin/sh
# Experimental FS-neutral *offline staging* for the installed Veyra Plasma
# edition. No partition formatting, bootloader updates or root switching.
# ext4, XFS, F2FS, Btrfs and other Linux filesystems may host this store.
# ShellCheck SC2015: each A && B || die pattern deliberately rejects either failed check.
# shellcheck disable=SC2015
set -eu

die() { echo "veyra-deployment: $*" >&2; exit 1; }
usage() {
    echo 'usage: veyra-deployment.sh init STORE-MOUNT | stage STORE-MOUNT SOURCE-ID NEW-ID | stage-pair STORE-MOUNT SOURCE-SYSTEM NEW-SYSTEM SOURCE-USER NEW-USER | verify STORE-MOUNT ID | verify-pair STORE-MOUNT SYSTEM-ID USER-ID' >&2
    exit 2
}
id_ok() {
    case "$1" in *..*) return 1 ;; esac
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
    [ ! -L "$store/deployments" ] && [ -d "$store/deployments" ] ||
        die 'deployment directory is missing or symlinked'
    printf '%s/deployments/%s\n' "$store" "$1"
}
user_environment_path() {
    id_ok "$1" || die "invalid user environment ID: $1"
    [ ! -L "$store/user-environments" ] && [ -d "$store/user-environments" ] ||
        die 'user environment directory is missing or symlinked'
    printf '%s/user-environments/%s\n' "$store" "$1"
}
verify_user_environment_root() {
    user_root=$1
    user_id=$2
    [ -d "$user_root" ] && [ ! -L "$user_root" ] ||
        die "missing real user environment directory: $user_id"
    for rel in etc etc/apk etc/veyra sbin; do
        [ ! -L "$user_root/$rel" ] && [ -d "$user_root/$rel" ] ||
            die "symlinked or missing user environment directory: $rel"
    done
    for rel in etc/apk/world etc/veyra/user-environment-id; do
        [ -f "$user_root/$rel" ] && [ ! -L "$user_root/$rel" ] ||
            die "missing real user environment metadata: $rel"
    done
    [ "$(cat "$user_root/etc/veyra/user-environment-id")" = "$user_id" ] ||
        die "user environment identity mismatch: $user_id"
    [ -s "$user_root/etc/apk/world" ] ||
        die "empty user environment APK world: $user_id"
    user_init=$(readlink -f "$user_root/sbin/init") ||
        die "missing user environment init: $user_id"
    case "$user_init" in
        "$user_root"/*) [ -f "$user_init" ] && [ -x "$user_init" ] ||
            die "user environment init is not executable: $user_id" ;;
        *) die "user environment init escapes its root: $user_id" ;;
    esac
}
verify_user_environment() {
    user_id=$1
    user_root=$(user_environment_path "$user_id")
    verify_user_environment_root "$user_root" "$user_id"
}
slot_user_id() {
    requested=$1
    slot=$(slot_path "$requested")
    marker="$slot/etc/veyra/user-environment-id"
    [ ! -L "$marker" ] || die "symlinked user environment selector: $requested"
    [ -e "$marker" ] || return 0
    [ -f "$marker" ] || die "invalid user environment selector: $requested"
    user_id=$(cat "$marker") || die "cannot read user environment selector: $requested"
    id_ok "$user_id" || die "invalid user environment ID in deployment: $requested"
    verify_user_environment "$user_id"
    for rel in var var/lib var/lib/veyra var/lib/veyra/user-root; do
        [ ! -L "$slot/$rel" ] && [ -d "$slot/$rel" ] ||
            die "unsafe or missing paired user root mountpoint: $rel"
    done
    printf '%s\n' "$user_id"
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
    slot_user_id "$requested" >/dev/null
    for path in home nix; do
        [ ! -L "$slot/$path" ] ||
            die "symlinked persistent mount placeholder: $path"
    done
}
verify_pair() {
    system_id=$1
    user_id=$2
    verify_slot "$system_id"
    selected_user=$(slot_user_id "$system_id")
    [ "$selected_user" = "$user_id" ] ||
        die "system deployment $system_id does not select user environment $user_id"
    verify_user_environment "$user_id"
}
copy_system_root() {
    copy_source=$1
    copy_target=$2
    new_id=$3
    mkdir "$copy_target"
    if ! rsync -aHAX --numeric-ids --one-file-system \
        --exclude='/home/***' --exclude='/nix/***' \
        --exclude='/proc/***' --exclude='/sys/***' \
        --exclude='/dev/***' --exclude='/run/***' \
        --exclude='/tmp/***' --exclude='/mnt/***' \
        --exclude='/media/***' \
        "$copy_source/" "$copy_target/"; then
        die "staging system copy failed; inspect $copy_target before cleanup"
    fi
    for runtime_dir in dev proc sys run tmp media mnt; do
        [ ! -L "$copy_target/$runtime_dir" ] ||
            die "symlinked staged runtime mountpoint: $runtime_dir"
        mkdir -p "$copy_target/$runtime_dir"
    done
    chmod 1777 "$copy_target/tmp"
    [ ! -L "$copy_target/etc/veyra/deployment-id" ] ||
        die 'staged deployment ID symlink rejected'
    printf '%s\n' "$new_id" > "$copy_target/etc/veyra/deployment-id"
}
copy_user_environment() {
    copy_source=$1
    copy_target=$2
    new_id=$3
    mkdir "$copy_target"
    if ! rsync -aHAX --numeric-ids --one-file-system \
        --exclude='/home/***' --exclude='/nix/***' \
        --exclude='/proc/***' --exclude='/sys/***' \
        --exclude='/dev/***' --exclude='/run/***' \
        --exclude='/tmp/***' --exclude='/mnt/***' \
        --exclude='/media/***' \
        "$copy_source/" "$copy_target/"; then
        die "staging user environment copy failed; inspect $copy_target before cleanup"
    fi
    for runtime_dir in dev proc sys run tmp media mnt home nix; do
        [ ! -L "$copy_target/$runtime_dir" ] ||
            die "symlinked staged user runtime mountpoint: $runtime_dir"
        mkdir -p "$copy_target/$runtime_dir"
    done
    chmod 1777 "$copy_target/tmp"
    [ ! -L "$copy_target/etc/veyra/user-environment-id" ] ||
        die 'staged user environment ID symlink rejected'
    printf '%s\n' "$new_id" > "$copy_target/etc/veyra/user-environment-id"
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
        for dir in deployments user-environments persistent/home persistent/nix persistent/shared boot-state; do
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
    verify-pair)
        [ "$#" -eq 4 ] || usage
        marker_ok
        verify_pair "$3" "$4"
        echo "Verified Veyra deployment pair $3+$4 on $filesystem"
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
        # No snapshots, reflinks or filesystem-specific commands. Root tree
        # must be QUIESCENT: callers cannot stage from the actively changing /.
        # Never import persistent mounts, bootloader state or child filesystems.
        [ -x "$(command -v rsync)" ] || die 'rsync is required for safe offline root copies'
        copy_system_root "$source" "$temp" "$4"
        # Verify before exposing the new ID; a rename within this mount is
        # atomic, but it is NOT a bootloader/OTA commit.
        [ -f "$temp/etc/apk/world" ] || die 'staged root missing APK world'
        mv -T "$temp" "$target"
        verify_slot "$4"
        echo "Staged inactive Veyra deployment $4 on $filesystem; boot unchanged"
        ;;
    stage-pair)
        [ "$#" -eq 6 ] || usage
        marker_ok
        id_ok "$3" && id_ok "$4" && id_ok "$5" && id_ok "$6" ||
            die 'invalid system or user environment ID'
        [ "$3" != "$4" ] || die 'cannot stage system deployment onto itself'
        [ "$5" != "$6" ] || die 'cannot stage user environment onto itself'
        verify_slot "$3"
        verify_user_environment "$5"
        source_system=$(slot_path "$3")
        source_user=$(user_environment_path "$5")
        linked_user=$(slot_user_id "$3")
        [ "$linked_user" = "$5" ] ||
            die "source system $3 is not paired with user environment $5"
        target_system=$(slot_path "$4")
        target_user=$(user_environment_path "$6")
        temp_system="$store/deployments/.staging-system-$4"
        temp_user="$store/user-environments/.staging-user-$6"
        [ ! -e "$target_system" ] && [ ! -L "$target_system" ] ||
            die "target system deployment already exists: $4"
        [ ! -e "$target_user" ] && [ ! -L "$target_user" ] ||
            die "target user environment already exists: $6"
        [ ! -e "$temp_system" ] && [ ! -L "$temp_system" ] ||
            die 'system staging directory already exists (manual recovery required)'
        [ ! -e "$temp_user" ] && [ ! -L "$temp_user" ] ||
            die 'user staging directory already exists (manual recovery required)'
        [ -x "$(command -v rsync)" ] || die 'rsync is required for safe offline root copies'
        # Both sources must be QUIESCENT. Rename the user root first so a
        # failed system rename can leave only an unreferenced orphan. The
        # system boot entry appears only after both complete roots exist.
        copy_user_environment "$source_user" "$temp_user" "$6"
        verify_user_environment_root "$temp_user" "$6"
        copy_system_root "$source_system" "$temp_system" "$4"
        [ ! -L "$temp_system/etc/veyra/user-environment-id" ] ||
            die 'source system user-environment selector is symlinked'
        printf '%s\n' "$6" > "$temp_system/etc/veyra/user-environment-id"
        [ -f "$temp_system/etc/apk/world" ] &&
            [ -f "$temp_system/boot/vmlinuz-lts" ] &&
            [ -f "$temp_system/boot/initramfs-lts" ] ||
            die 'staged system deployment is missing bootable system metadata'
        mv -T "$temp_user" "$target_user"
        mv -T "$temp_system" "$target_system"
        verify_pair "$4" "$6"
        echo "Staged inactive Veyra deployment pair $4+$6 on $filesystem; boot unchanged"
        ;;
    *) usage ;;
esac
