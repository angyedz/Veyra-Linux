#!/bin/sh
# Install the optional Veyra userspace integrations on an Alpine host.
set -eu

[ "$(id -u)" -eq 0 ] || { echo 'Run as root inside Alpine Linux' >&2; exit 1; }
[ -f /etc/alpine-release ] || { echo 'Requires Alpine Linux' >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo 'Only x86_64 currently supported' >&2; exit 1; }

scriptdir=$(CDPATH= cd "$(dirname "$0")" && pwd)
apk update
apk add ca-certificates curl git bash xz tar shadow sudo openrc dbus dbus-openrc

if [ "${ENABLE_COMPAT:-1}" = 1 ]; then
    sh "$scriptdir/compat.sh"
fi

if [ "${ENABLE_GLENV:-1}" = 1 ]; then
    : "${GLENV_REF:=main}"
    mkdir -p /opt
    if [ ! -d /opt/glenv-src/.git ]; then
        git clone https://github.com/angyedz/glenv.git /opt/glenv-src
    fi
    git -C /opt/glenv-src fetch --tags origin
    git -C /opt/glenv-src checkout --detach "$GLENV_REF"
    (cd /opt/glenv-src && sh install.sh --yes)
fi

if [ "${ENABLE_NIX:-1}" = 1 ]; then
    # Alpine's musl-native Nix and its maintained OpenRC service.
    apk add nix nix-openrc
    rc-update add nix-daemon default
    rc-service nix-daemon start
fi

echo 'Veyra components installed. Run the smoke checks after reboot.'
