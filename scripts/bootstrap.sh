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
apk add vpkg

if [ "${ENABLE_COMPAT:-1}" = 1 ]; then
    sh "$scriptdir/compat.sh"
fi

if [ "${ENABLE_GLENV:-1}" = 1 ]; then
    apk add veyra-glenv
    veyra-glenv --yes
fi

if [ "${ENABLE_NIX:-1}" = 1 ]; then
    # Alpine's musl-native Nix and its maintained OpenRC service.
    apk add nix nix-openrc
    mkdir -p /etc/nix
    nix_config=/etc/nix/nix.conf
    nix_config_tmp=$(mktemp /etc/nix/nix.conf.XXXXXX)
    if [ -f "$nix_config" ]; then
        awk '
            /^[[:space:]]*extra-experimental-features[[:space:]]*=/ {
                if (!seen) {
                    value=$0
                    sub(/^[^=]*=/, "", value)
                    if (value !~ /(^|[[:space:]])nix-command([[:space:]]|$)/) value=value " nix-command"
                    if (value !~ /(^|[[:space:]])flakes([[:space:]]|$)/) value=value " flakes"
                    print "extra-experimental-features =" value
                    seen=1
                }
                next
            }
            { print }
            END { if (!seen) print "extra-experimental-features = nix-command flakes" }
        ' "$nix_config" > "$nix_config_tmp"
    else
        printf '%s\n' 'extra-experimental-features = nix-command flakes' > "$nix_config_tmp"
    fi
    chmod 0644 "$nix_config_tmp"
    mv "$nix_config_tmp" "$nix_config"
    rc-update add nix-daemon default
    rc-service nix-daemon start
fi

echo 'Veyra components installed. Run the smoke checks after reboot.'
