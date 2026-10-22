#!/bin/sh
# Install the optional Veyra userspace integrations on an Alpine host.
set -eu

[ "$(id -u)" -eq 0 ] || { echo 'Run as root inside Alpine Linux' >&2; exit 1; }
[ -f /etc/alpine-release ] || { echo 'Requires Alpine Linux' >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo 'Only x86_64 currently supported' >&2; exit 1; }

scriptdir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
apk update
apk add ca-certificates curl git bash xz tar shadow sudo openrc dbus dbus-openrc
sh "$scriptdir/setup-pkgrepo.sh"
apk update
apk add vpkg@veyra

if [ "${ENABLE_COMPAT:-1}" = 1 ]; then
    sh "$scriptdir/compat.sh"
fi

if [ "${ENABLE_GLENV:-1}" = 1 ]; then
    apk add veyra-glenv@veyra
    veyra-glenv --yes
fi

if [ "${ENABLE_NIX:-1}" = 1 ]; then
    # Alpine's musl-native Nix and its maintained OpenRC service.
    apk add nix nix-openrc
    rc-update add nix-daemon default
    rc-service nix-daemon start
fi

echo 'Veyra components installed. Run the smoke checks after reboot.'
