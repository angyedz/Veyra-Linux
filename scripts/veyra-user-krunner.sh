#!/bin/sh
# Experimental KDE session-side KRunner launch guard for a *pre-existing*
# isolated Veyra user environment. Not a substitute for namespaces or for
# disabling all host-side KRunner / D-Bus activation paths.
# This file is not installed or enabled by default.
set -eu

die() { printf 'veyra-user-krunner: %s\n' "$*" >&2; exit 1; }

case "$#" in
    0) check_only=0 ;;
    1)
        [ "$1" = --check ] || die 'usage: veyra-user-krunner.sh [--check]'
        check_only=1
        ;;
    *) die 'usage: veyra-user-krunner.sh [--check]' ;;
esac

# Never execute KRunner as user-namespace root. The desktop's ordinary user
# and its sudo privilege escalation are separate from the system host.
[ "$(id -u)" -ne 0 ] || die 'refusing to run a desktop as root'
[ -r /proc/self/uid_map ] || die 'missing user namespace mapping'

# Reject the initial host user namespace (identity map includes host UID 0).
# A properly configured environment maps its UID 0 to an unprivileged host UID.
# This is defense-in-depth against a misconfigured launch, NOT an isolation
# proof, and it cannot replace proper system namespace and service policies.
awk '
    $1 == 0 { seen = 1 }
    $2 == 0 { exit 1 }
    END { if (!seen) exit 1 }
' /proc/self/uid_map || die 'not in an unprivileged user namespace'

# Only an environment-owned session bus is allowed. Never use an inherited
# DBUS_SESSION_BUS_ADDRESS, which could select a privileged host bus.
[ -n "${XDG_RUNTIME_DIR:-}" ] || die 'missing user runtime directory'
case "$XDG_RUNTIME_DIR" in
    /run/user/*) : ;;
    *) die 'runtime directory must be below the isolated /run/user' ;;
esac
[ ! -L "$XDG_RUNTIME_DIR" ] || die 'symlinked runtime directory'
[ -d "$XDG_RUNTIME_DIR" ] || die 'user runtime directory unavailable'
[ "$(stat -c %u "$XDG_RUNTIME_DIR")" = "$(id -u)" ] ||
    die 'runtime directory owner does not match user'
[ -S "$XDG_RUNTIME_DIR/bus" ] || die 'user D-Bus session bus unavailable'
DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
export DBUS_SESSION_BUS_ADDRESS

[ "$check_only" -eq 0 ] || {
    echo 'veyra-user-krunner: isolated namespace mapping and user bus preflight passed'
    exit 0
}

# This binary must be the system-version-paired, read-only KDE runtime
# exposed *inside* the user environment. It must never be invoked on host.
[ -x /usr/bin/krunner ] || die 'isolated KDE KRunner executable missing'
exec /usr/bin/krunner --daemon
