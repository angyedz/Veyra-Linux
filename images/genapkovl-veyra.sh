#!/bin/sh
# Run from mkimage's DESTDIR; output <hostname>.apkovl.tar.gz in the CWD.
set -eu
host="${1:-veyra}"
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)

mkdir -p etc/apk usr/local/bin usr/local/lib/veyra

printf '%s\n' veyra > etc/hostname
printf '%s\n' 'Veyra Linux — lightweight by design.' > etc/motd
printf '%s\n' 'Veyra Linux (experimental)' > etc/issue
printf '%s\n' 'Veyra Linux development image' > etc/veyra-release

# The booting live image uses this list to install packages from its ISO cache.
cat > etc/apk/world <<'WORLD'
alpine-base
bash
ca-certificates
curl
dbus
dbus-openrc
elogind
git
nano
networkmanager
nix
nix-openrc
polkit
sudo
WORLD

cp "$root/scripts/bootstrap.sh" usr/local/lib/veyra/bootstrap.sh
cp "$root/scripts/compat.sh" usr/local/lib/veyra/compat.sh
cp "$root/scripts/smoke.sh" usr/local/lib/veyra/smoke.sh

cat > usr/local/bin/veyra-setup <<'SETUP'
#!/bin/sh
exec sh /usr/local/lib/veyra/bootstrap.sh "$@"
SETUP
chmod 755 usr/local/bin/veyra-setup
tar -czf "$host.apkovl.tar.gz" etc usr
