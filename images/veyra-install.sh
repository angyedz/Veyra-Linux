#!/bin/sh
set -eu
tui_launcher=${VEYRA_TUI_LAUNCHER:-/usr/local/bin/veyra-install-tui}
tui_script=${VEYRA_TUI_INSTALL_SCRIPT:-/usr/local/lib/veyra/tui-install.sh}
show_error() {
    if command -v kdialog >/dev/null 2>&1; then
        kdialog --title 'Veyra Linux installer' --error "$1" || true
    else
        printf '%s\n' "$1" >&2
    fi
}
offer_text_installer() {
    if command -v kdialog >/dev/null 2>&1 && command -v konsole >/dev/null 2>&1 \
        && [ -x "$tui_launcher" ]; then
        if kdialog --title 'Veyra Linux installer' --yesno \
            'Calamares could not open. Would you like to start the guided text installer instead?'; then
            konsole -e "$tui_launcher"
        fi
    fi
}

if [ "${1:-}" = --tui ] || [ "${1:-}" = --text ] || { [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; }; then
    exec sudo -n /bin/sh "$tui_script"
fi
if ! command -v calamares >/dev/null 2>&1; then
    show_error 'Calamares is unavailable.'
    offer_text_installer
    exit 1
fi

# SDDM's X11 session may keep the cookie in ~/.Xauthority. The privileged
# Calamares process needs the same cookie to connect to the live display.
if [ -z "${XAUTHORITY:-}" ] && [ -r "$HOME/.Xauthority" ]; then
    XAUTHORITY="$HOME/.Xauthority"
    export XAUTHORITY
fi

log="${XDG_CACHE_HOME:-$HOME/.cache}/veyra-calamares.log"
mkdir -p "$(dirname "$log")"
if sudo -n --preserve-env=DISPLAY,WAYLAND_DISPLAY,XDG_RUNTIME_DIR,DBUS_SESSION_BUS_ADDRESS,QT_QPA_PLATFORM,XAUTHORITY \
    /usr/bin/calamares >"$log" 2>&1; then
    exit 0
fi

show_error "Calamares could not start. Its log is at $log."
if command -v kdialog >/dev/null 2>&1 && [ -s "$log" ]; then
    kdialog --title 'Veyra Linux installer log' --textbox "$log" 760 500 || true
fi
offer_text_installer
exit 1
