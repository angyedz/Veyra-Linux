#!/bin/sh
set -eu
show_error() {
    if command -v kdialog >/dev/null 2>&1; then
        kdialog --title 'Veyra Linux installer' --error "$1"
    else
        printf '%s\n' "$1" >&2
    fi
}
offer_text_installer() {
    if command -v kdialog >/dev/null 2>&1 && command -v konsole >/dev/null 2>&1 \
        && [ -x /usr/local/bin/veyra-install-tui ]; then
        if kdialog --title 'Veyra Linux installer' --yesno \
            'Calamares could not open. Would you like to start the guided text installer instead?'; then
            konsole -e sudo /usr/local/bin/veyra-install-tui
        fi
    fi
}

if [ ! -x /usr/bin/calamares ]; then
    show_error 'Calamares is missing from this live image.'
    offer_text_installer
    exit 1
fi

log="${XDG_CACHE_HOME:-$HOME/.cache}/veyra-calamares.log"
mkdir -p "$(dirname "$log")"
# SDDM's X11 session may keep its cookie in ~/.Xauthority. The elevated
# Calamares process needs the same cookie to connect to the live display.
if [ -z "${XAUTHORITY:-}" ] && [ -r "$HOME/.Xauthority" ]; then
    XAUTHORITY="$HOME/.Xauthority"
    export XAUTHORITY
fi
# The live user owns this log path; capture output from the root installer.
# shellcheck disable=SC2024
if sudo -n --preserve-env=DISPLAY,WAYLAND_DISPLAY,XDG_RUNTIME_DIR,DBUS_SESSION_BUS_ADDRESS,QT_QPA_PLATFORM,XAUTHORITY \
    /usr/bin/calamares >"$log" 2>&1; then
    exit 0
fi

show_error "The installer could not start (or exited with an error). Its log is at $log."
if command -v kdialog >/dev/null 2>&1 && [ -s "$log" ]; then
    kdialog --title 'Veyra Linux installer log' --textbox "$log" 760 500 || true
else
    cat "$log" >&2
fi
offer_text_installer
exit 1
