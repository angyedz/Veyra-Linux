#!/bin/sh
set -eu
if ! command -v calamares >/dev/null 2>&1; then
    echo 'Calamares is not available in this development image yet.' >&2
    if command -v kdialog >/dev/null 2>&1; then
        kdialog --error 'Calamares is not available in this development image yet.' \
            --title 'Veyra Linux installer'
    fi
    exit 1
fi
exec sudo --preserve-env=DISPLAY,WAYLAND_DISPLAY,XDG_RUNTIME_DIR,DBUS_SESSION_BUS_ADDRESS,QT_QPA_PLATFORM /usr/bin/calamares
