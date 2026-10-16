#!/bin/sh
set -eu
if [ "${1:-}" = --tui ] || [ "${1:-}" = --text ] || { [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; }; then
    exec /bin/sh /usr/local/lib/veyra/tui-install.sh
fi
if ! command -v calamares >/dev/null 2>&1; then
    echo 'Calamares unavailable; starting TUI installer.' >&2
    exec /bin/sh /usr/local/lib/veyra/tui-install.sh
fi
exec sudo --preserve-env=DISPLAY,WAYLAND_DISPLAY,XDG_RUNTIME_DIR,DBUS_SESSION_BUS_ADDRESS,QT_QPA_PLATFORM /usr/bin/calamares
