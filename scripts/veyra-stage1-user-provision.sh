#!/bin/sh
# Disposable QEMU-only system-side account rootfs provisioner.
set -eu
store=/var/lib/veyra-user-store
users=$store/users
users_file=/etc/veyra/stage1-user-accounts
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
if [ "$mount_source" != /dev/vdb ] || [ "$mount_type" != ext4 ]; then
    fail "persistent store must be the ext4 /dev/vdb mount"
fi
if [ ! -d "$store" ] || [ -L "$store" ]; then
    fail "persistent user store is missing or a symlink"
fi
if [ -L "$users_file" ] || [ ! -f "$users_file" ] ||
   [ "$(/bin/busybox stat -c '%u:%g:%a' "$users_file")" != "0:0:644" ]; then
    fail "account manifest must be a system-root-owned regular 0644 file"
fi
if [ ! -d "$template" ] || [ -L "$template" ] ||
   [ ! -x "$template/sbin/init" ] ||
   [ ! -f "$template/.veyra-stage1-rootfs" ] ||
   [ ! -d "$template/home/veyrauser" ] ||
   [ ! -x "$template/usr/bin/sudo" ]; then
    fail "trusted system user-root template is incomplete"
fi

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
trap cleanup EXIT
trap 'exit 1' INT TERM

# The system-owned manifest has one login/store name and one reserved outer
# UID/GID base per environment. Each 100000-step slot contains one 65536-ID
# user namespace range, leaving a gap so ranges cannot overlap.
seen_accounts=" "
seen_bases=" "
account_count=0
while IFS=: read -r account base extra || [ -n "$account$base$extra" ]; do
    [ -n "$account$base$extra" ] || continue
    [ -n "$account" ] && [ -n "$base" ] && [ -z "$extra" ] ||
        fail "each account record must contain exactly name:uid-base"
    case "$account" in
        [a-z_]* ) ;;
        *) fail "invalid account name in system manifest" ;;
    esac
    case "$account" in
        *[!a-z0-9_-]*) fail "invalid account name in system manifest" ;;
    esac
    account_length=$(/bin/busybox printf '%s' "$account" | /bin/busybox wc -c)
    [ "$account_length" -le 32 ] ||
        fail "account name exceeds 32 bytes"
    case "$base" in
        [1-9]*) ;;
        *) fail "invalid mapped UID/GID base in system manifest" ;;
    esac
    case "$base" in
        *[!0-9]*) fail "invalid mapped UID/GID base in system manifest" ;;
    esac
    base_length=$(/bin/busybox printf '%s' "$base" | /bin/busybox wc -c)
    [ "$base_length" -le 10 ] ||
        fail "mapped UID/GID base is out of range"
    [ "$base" -ge 100000 ] && [ "$base" -le 2147400000 ] &&
        [ "$((base % 100000))" -eq 0 ] ||
        fail "mapped UID/GID base must be a unique 100000-ID slot"
    case "$seen_accounts" in
        *" $account "*) fail "duplicate account name in system manifest" ;;
    esac
    case "$seen_bases" in
        *" $base "*) fail "duplicate UID/GID range in system manifest" ;;
    esac
    seen_accounts="$seen_accounts$account "
    seen_bases="$seen_bases$base "
    account_count=$((account_count + 1))
    [ "$account_count" -le 64 ] ||
        fail "system manifest exceeds the 64-account test limit"
done < "$users_file"
[ "$account_count" -gt 0 ] || fail "system account manifest is empty"
case "$seen_accounts" in *" alice "*) ;; *) fail "manager fixture requires alice" ;; esac
case "$seen_accounts" in *" bob "*) ;; *) fail "manager fixture requires bob" ;; esac

for entry in "$users"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    entry_name=$(/bin/busybox basename "$entry")
    case "$seen_accounts" in
        *" $entry_name "*) ;;
        *) fail "unexpected entry in managed users directory" ;;
    esac
done

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
        if [ ! -d "$target" ] || [ -L "$target" ]; then
            fail "$account rootfs is not a real directory"
        fi
        if [ ! -f "$target/.veyra-stage1-rootfs" ] ||
           [ -L "$target/.veyra-stage1-rootfs" ]; then
            fail "$account rootfs is missing its Veyra marker"
        fi
        if [ ! -f "$target/.veyra-stage1-account" ] ||
           [ -L "$target/.veyra-stage1-account" ] ||
           [ "$(/bin/busybox cat "$target/.veyra-stage1-account")" != "$account" ]; then
            fail "$account rootfs identity does not match its account"
        fi
        [ "$(/bin/busybox stat -c '%u:%g:%a' "$target")" = "$base:$home_id:710" ] ||
            fail "$account rootfs has an unexpected owner or mode"
        echo "VEYRA_STAGE1_USER_ROOT_REUSED account=$account outer-uid-base=$base"
    fi
}

while IFS=: read -r account base extra || [ -n "$account$base$extra" ]; do
    [ -n "$account$base$extra" ] || continue
    provision_one "$account" "$base"
done < "$users_file"

bind_root() {
    source=$1
    target=$2
    expected_mount_root=$3
    if [ ! -d "$target" ] || [ -L "$target" ]; then
        fail "rootfs mountpoint $target is missing or a symlink"
    fi
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
