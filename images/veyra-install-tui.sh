#!/bin/sh
# Compatibility launcher: both entry points install Veyra, not bare Alpine.
set -eu
[ -r /etc/veyra-release ] || {
    echo 'Run the installer from Veyra Live ISO.' >&2
    exit 1
}
exec /usr/local/bin/veyra-install --tui
