#!/bin/sh
set -eu
[ -f /etc/alpine-release ] || exit 1
command -v apk >/dev/null
command -v rc-service >/dev/null
command -v vpkg >/dev/null
apk policy vpkg | grep -q "vpkg"
if [ "${ENABLE_GLENV:-1}" = 1 ]; then
    command -v glenv >/dev/null || { echo 'glenv not installed' >&2; exit 1; }
    glenv doctor
fi
if [ "${ENABLE_NIX:-1}" = 1 ]; then
    command -v nix >/dev/null || { echo 'Nix not installed' >&2; exit 1; }
    nix --version
fi
if [ "${ENABLE_COMPAT:-1}" = 1 ]; then
    rc-service dbus status
    rc-service networkmanager status
fi
