#!/bin/sh
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
target="$tmp/target"
mkdir -p "$tmp/bin" "$target/etc/apk/keys" "$target/etc" \
    "$target/lib/modules/6.12.0-test" "$target/boot"
printf '%s\n' alpine-base > "$target/etc/apk/world"
printf '%s\n' 'public-key-fixture' > "$target/etc/apk/keys/veyra.rsa.pub"
printf '%s\n' root:x:0:0:root:/root:/bin/sh > "$target/etc/passwd"
: > "$target/boot/vmlinuz-lts"

cat > "$tmp/bin/mountpoint" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$tmp/bin/chroot" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod 755 "$tmp/bin/"*
PATH="$tmp/bin:$PATH" sh "$root/scripts/installer-prepare.sh" "$target" >/dev/null

grep -qx 'https://dl-cdn.alpinelinux.org/alpine/v3.22/main' "$target/etc/apk/repositories"
grep -qx 'https://dl-cdn.alpinelinux.org/alpine/v3.22/community' "$target/etc/apk/repositories"
grep -qx 'https://raw.githubusercontent.com/angyedz/Veyra-Linux/main/packages/repo/x86_64' \
    "$target/etc/apk/repositories"
printf '%s\n' 'Veyra signed repository configuration passed'
