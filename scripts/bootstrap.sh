#!/bin/sh
set -eu

[ "$(id -u)" -eq 0 ] || { echo 'Run as root inside Alpine VM' >&2; exit 1; }
[ -f /etc/alpine-release ] || { echo 'Requires Alpine Linux' >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo 'Only x86_64 currently supported' >&2; exit 1; }

apk update
apk add ca-certificates curl git bash xz tar shadow sudo openrc dbus dbus-openrc

if [ "${ENABLE_COMPAT:-1}" = 1 ]; then
  sh "$(dirname "$0")/compat.sh"
fi

if [ "${ENABLE_GLENV:-1}" = 1 ]; then
  : "${GLENV_REF:=main}"
  mkdir -p /opt
  if [ ! -d /opt/glenv-src/.git ]; then git clone https://github.com/angyedz/glenv.git /opt/glenv-src; fi
  git -C /opt/glenv-src fetch --tags origin
  git -C /opt/glenv-src checkout --detach "$GLENV_REF"
  (cd /opt/glenv-src && sh install.sh --yes)
fi

if [ "${ENABLE_NIX:-1}" = 1 ]; then
  if ! command -v nix >/dev/null 2>&1; then
    echo 'Installing upstream Nix in multi-user mode (review upstream installer first)'
    curl -fsSL https://nixos.org/nix/install -o /tmp/nix-install.sh
    sh /tmp/nix-install.sh --daemon
  fi
  install -m 755 "$(dirname "$0")/nix-daemon.initd" /etc/init.d/nix-daemon
  rc-update add nix-daemon default
  rc-service nix-daemon start
fi

echo 'Bootstrap finished. Reboot and run scripts/smoke.sh.'
