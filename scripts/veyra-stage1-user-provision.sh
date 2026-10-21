#!/bin/sh
# Disposable QEMU-only system-side account rootfs provisioner.
set -eu
store=/var/lib/veyra-user-store
users=$store/users
template=/usr/share/veyra/stage1-user-template
root_a=/mnt/veyra-user
root_b=/mnt/veyra-user-b
lock=/run/veyra-stage1-user-provisioning-lock
tmp=

fail() {
    echo "VEYRA_STAGE1_FAILURE: user-root provisioning: $*" >&2
    exit 1
}
mount_source=$(awk -v target="$store" '$2 == target { print $1; exit }' /proc/mounts)
mount_type=$(awk -v target="$store" '$2 == target { print $3; exit }' /proc/mounts)
[ "$mount_source" = /dev/vdb ] && [ "$mount_type" = ext4 ] ||
    fail "persistent store must be the ext4 /dev/vdb mount"
[ -d "$store" ] && [ ! -L "$store" ] ||
    fail "persistent user store is missing or a symlink"
[ -d "$template" ] && [ ! -L "$template" ] &&
    [ -x "$template/sbin/init" ] &&
    [ -f "$template/.veyra-stage1-rootfs" ] ||
    fail "trusted system user-root template is incomplete"

if [ -L "$users" ]; then
    fail "user directory is a symlink"
fi
if [ ! -d "$users" ]; then
    mkdir "$users"
    chown 0:0 "$users"
    chmod 0711 "$users"
fi
[ "$(/bin/busybox stat -c '%u:%g:%a' "$users")" = "0:0:711" ] ||
    fail "user directory must remain system-root-owned and non-writable"
if ! mkdir "$lock" 2>/dev/null; then
    fail "another provisioner is active or a prior run left an incomplete lock"
fi
cleanup() {
    [ -z "$tmp" ] || rm -rf -- "$tmp"
    rmdir "$lock" 2>/dev/null || :
}
trap cleanup EXIT INT TERM

provision_one() {
    account=$1
    base=$2
    home_id=$((base + 1000))
    target=$users/$account
    if [ -L "$target" ]; then
        fail "$account rootfs path is a symlink"
    fi
    if [ ! -e "$target" ]; then
        tmp=$users/.$account.provision.$$
        mkdir "$tmp" || fail "cannot create staging root for $account"
        cp -a "$template/." "$tmp/" || fail "cannot stage template for $account"
        chown -hR "$base:$base" "$tmp" ||
            fail "cannot assign the dedicated host ID range for $account"
        printf '%s\n' "$account" > "$tmp/.veyra-stage1-account"
        chown "$base:$base" "$tmp/.veyra-stage1-account"
        chmod 0444 "$tmp/.veyra-stage1-account"
        chown "$home_id:$home_id" "$tmp/home/veyrauser"
        chmod 0700 "$tmp/home/veyrauser"
        chmod 4755 "$tmp/usr/bin/sudo"
        chown "$base:$((base + 1000))" "$tmp"
        chmod 0710 "$tmp"
        mv "$tmp" "$target" || fail "cannot atomically publish $account rootfs"
        tmp=
        echo "VEYRA_STAGE1_USER_ROOT_PROVISIONED account=$account outer-uid-base=$base"
    else
        [ -d "$target" ] && [ ! -L "$target" ] ||
            fail "$account rootfs is not a real directory"
        [ -f "$target/.veyra-stage1-rootfs" ] &&
            [ ! -L "$target/.veyra-stage1-rootfs" ] ||
            fail "$account rootfs is missing its Veyra marker"
        [ -f "$target/.veyra-stage1-account" ] &&
            [ ! -L "$target/.veyra-stage1-account" ] &&
            [ "$(/bin/busybox cat "$target/.veyra-stage1-account")" = "$account" ] ||
            fail "$account rootfs identity does not match its account"
        [ "$(/bin/busybox stat -c '%u:%g:%a' "$target")" = "$base:$home_id:710" ] ||
            fail "$account rootfs has an unexpected owner or mode"
        echo "VEYRA_STAGE1_USER_ROOT_REUSED account=$account outer-uid-base=$base"
    fi
}

for entry in "$users"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "$entry" in
        "$users/alice"|"$users/bob") ;;
        *) fail "unexpected entry in managed users directory" ;;
    esac
done

provision_one alice 100000
provision_one bob 200000

bind_root() {
    source=$1
    target=$2
    expected_mount_root=$3
    [ -d "$target" ] && [ ! -L "$target" ] ||
        fail "rootfs mountpoint $target is missing or a symlink"
    if awk -v target="$target" '$5 == target { found=1 } END { exit !found }' /proc/self/mountinfo; then
        awk -v target="$target" -v root="$expected_mount_root" \
            '$5 == target && $4 == root { found=1 } END { exit !found }' \
            /proc/self/mountinfo ||
            fail "existing mount at $target is not the expected account root"
    else
        mount --bind "$source" "$target" ||
            fail "cannot mount persistent account root at $target"
    fi
}
bind_root "$users/alice" "$root_a" /users/alice
bind_root "$users/bob" "$root_b" /users/bob
echo "VEYRA_STAGE1_USER_ROOTS_READY alice=$root_a bob=$root_b distinct-id-ranges=1"
