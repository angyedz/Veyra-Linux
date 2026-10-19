#!/bin/sh
# Experimental session-side KRunner preflight, NOT a host security boundary.
# Not installed/enabled in Veyra's boot, shortcuts, D-Bus or installer.
set -eu
die() { printf 'veyra-user-krunner: %s\n' "$*" >&2; exit 1; }
case "$#" in
    0) check_only=0 ;;
    1) [ "$1" = --check ] || die 'usage: veyra-user-krunner.sh [--check]'
       check_only=1 ;;
    *) die 'usage: veyra-user-krunner.sh [--check]' ;;
esac
[ "$(id -u)" -ne 0 ] || die 'refusing desktop execution as root'
[ -r /proc/self/uid_map ] || die 'no user namespace mapping'
# Require namespace UID 0 mapped away from host 0 and reject any map to host 0.
awk '
    $2 == 0 { invalid=1 }
    $1 == 0 && $2 != 0 { mapped_root=1 }
    END { if (invalid || !mapped_root) exit 1 }
' /proc/self/uid_map || die 'not in an unprivileged user namespace'
[ -n "${XDG_RUNTIME_DIR:-}" ] || die 'missing private runtime directory'
case "$XDG_RUNTIME_DIR" in
    /run/user/*) : ;;
    *) die 'runtime directory must be under isolated /run/user' ;;
esac
[ "${XDG_RUNTIME_DIR##*/}" = "$(id -u)" ] ||
    die 'runtime directory does not match session uid'
if [ ! -d "$XDG_RUNTIME_DIR" ] || [ -L "$XDG_RUNTIME_DIR" ]; then
    die 'runtime directory missing or symlinked'
fi
[ "$(stat -c '%u' "$XDG_RUNTIME_DIR")" = "$(id -u)" ] ||
    die 'runtime directory belongs to another user'
if [ ! -S "$XDG_RUNTIME_DIR/bus" ] || [ -L "$XDG_RUNTIME_DIR/bus" ]; then
    die 'isolated session bus missing or symlinked'
fi
DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
export DBUS_SESSION_BUS_ADDRESS
# Provisional readonly system-generation runtime mount; not yet implemented.
runtime=/run/veyra/system-kde
command -v mountpoint >/dev/null 2>&1 || die 'missing mountpoint'
command -v findmnt >/dev/null 2>&1 || die 'missing findmnt'
mountpoint -q "$runtime" || die 'system KDE runtime not mounted'
findmnt -n -o OPTIONS -M "$runtime" | grep -Eq '(^|,)ro(,|$)' ||
    die 'system KDE runtime not read-only'
[ -x "$runtime/bin/krunner" ] || die 'paired KRunner not present'
if [ "$check_only" -eq 1 ]; then
    echo 'PASS: namespace/bus/runtime preflight only; no origin/ABI proof'
    exit 0
fi
# Host-side activation paths, overmounts, Qt plugins and loaders require
# a separate verified launch/mount contract; this wrapper cannot prove it.
exec "$runtime/bin/krunner"
