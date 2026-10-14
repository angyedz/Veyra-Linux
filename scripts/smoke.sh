#!/bin/sh
set -eu
[ -f /etc/alpine-release ]
command -v apk
command -v rc-service
if command -v glenv >/dev/null 2>&1; then glenv doctor; else echo 'glenv not installed' >&2; exit 1; fi
if command -v nix >/dev/null 2>&1; then nix --version; elif [ -x /nix/var/nix/profiles/default/bin/nix ]; then /nix/var/nix/profiles/default/bin/nix --version; else echo 'Nix not installed' >&2; exit 1; fi
rc-service dbus status
rc-service networkmanager status
