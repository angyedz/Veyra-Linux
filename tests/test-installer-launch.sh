#!/bin/sh
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
launcher=${VEYRA_INSTALLER_SCRIPT:-$root/images/veyra-install.sh}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
bin="$tmp/bin"
no_calamares="$tmp/no-calamares"
home="$tmp/home"
cache="$tmp/cache"
log="$tmp/commands.log"
ui_log="$tmp/ui.log"
tui_launcher="$tmp/veyra-install-tui"
tui_script="$tmp/tui-install.sh"
mkdir -p "$bin" "$no_calamares" "$home" "$cache"
: > "$log"
: > "$ui_log"
: > "$home/.Xauthority"

cat > "$bin/sudo" <<'STUB'
#!/bin/sh
printf 'ARGS=%s\nAUTH=%s\n' "$*" "${XAUTHORITY:-}" >> "$VEYRA_TEST_LOG"
case " $* " in
    *" /usr/bin/calamares "*)
        printf '%s\n' 'mock Calamares diagnostic'
        exit "${VEYRA_CALAMARES_RC:-0}"
        ;;
esac
exit 0
STUB
cat > "$bin/calamares" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$bin/kdialog" <<'STUB'
#!/bin/sh
printf 'KDIALOG=%s\n' "$*" >> "$VEYRA_UI_LOG"
case "${1:-}" in
    --yesno) exit "${VEYRA_YESNO_RC:-1}" ;;
esac
exit 0
STUB
cat > "$bin/konsole" <<'STUB'
#!/bin/sh
printf 'KONSOLE=%s\n' "$*" >> "$VEYRA_UI_LOG"
exit 0
STUB
cat > "$tui_launcher" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod 755 "$bin/"* "$tui_launcher"
ln -s "$bin/sudo" "$no_calamares/sudo"
ln -s "$bin/kdialog" "$no_calamares/kdialog"
ln -s "$bin/konsole" "$no_calamares/konsole"

export PATH="$bin:$PATH"
export HOME="$home"
export XDG_CACHE_HOME="$cache"
export VEYRA_TEST_LOG="$log"
export VEYRA_UI_LOG="$ui_log"
export VEYRA_TUI_LAUNCHER="$tui_launcher"
export VEYRA_TUI_INSTALL_SCRIPT="$tui_script"
export DISPLAY=:99
unset WAYLAND_DISPLAY XAUTHORITY || :

# A successful GUI launch passes the X11 cookie and records diagnostics.
if sh "$launcher"; then :; else
    echo 'Calamares success fixture unexpectedly failed' >&2
    exit 1
fi
grep -Fq 'ARGS=-n --preserve-env=DISPLAY,WAYLAND_DISPLAY,XDG_RUNTIME_DIR,DBUS_SESSION_BUS_ADDRESS,QT_QPA_PLATFORM,XAUTHORITY /usr/bin/calamares' "$log"
grep -Fq "AUTH=$home/.Xauthority" "$log"
grep -Fq 'mock Calamares diagnostic' "$cache/veyra-calamares.log"
test ! -s "$ui_log"

# Failed GUI launch exposes its log and offers the passwordless TUI fallback.
: > "$log"
: > "$ui_log"
export VEYRA_CALAMARES_RC=23
export VEYRA_YESNO_RC=0
if sh "$launcher"; then
    echo 'Calamares failure fixture unexpectedly succeeded' >&2
    exit 1
fi
grep -Fq -- '--error Calamares could not start.' "$ui_log"
grep -Fq -- '--textbox ' "$ui_log"
grep -Fq "KONSOLE=-e $tui_launcher" "$ui_log"

# An explicitly selected Xauthority cookie is preserved as-is.
: > "$log"
: > "$ui_log"
export XAUTHORITY="$tmp/custom-Xauthority"
export VEYRA_YESNO_RC=1
if sh "$launcher"; then
    echo 'Calamares failure fixture unexpectedly succeeded' >&2
    exit 1
fi
grep -Fq "AUTH=$XAUTHORITY" "$log"

# Missing Calamares from a desktop launcher shows an error and opens TUI in Konsole.
: > "$log"
: > "$ui_log"
export DISPLAY=:99
export VEYRA_YESNO_RC=0
if PATH="$no_calamares:/usr/bin:/bin" sh "$launcher"; then
    echo 'Missing Calamares fixture unexpectedly succeeded' >&2
    exit 1
fi
grep -Fq -- '--error Calamares is unavailable.' "$ui_log"
grep -Fq "KONSOLE=-e $tui_launcher" "$ui_log"

# Text mode and missing Calamares without a display use non-interactive sudo.
: > "$log"
unset DISPLAY XAUTHORITY
sh "$launcher" --tui
grep -Fq "ARGS=-n /bin/sh $tui_script" "$log"
: > "$log"
PATH="$no_calamares:/usr/bin:/bin" sh "$launcher"
grep -Fq "ARGS=-n /bin/sh $tui_script" "$log"

echo 'Installer launcher Xauthority, logging, fallback and no-password paths passed'
