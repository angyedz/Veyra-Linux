#!/bin/sh
# Emergency text-mode installation path for machines without a working Plasma session.
# Uses Alpine's supported setup-alpine installer; this is NOT the Veyra Calamares pipeline.
set -eu
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi
if [ ! -e /etc/veyra-release ]; then
    echo "This recovery tool must be run from Veyra live media." >&2
    exit 1
fi
if ! command -v setup-alpine >/dev/null 2>&1; then
    echo "Missing alpine-conf (setup-alpine)." >&2
    exit 1
fi
clear 2>/dev/null || true
cat <<'BANNER'
=========================================================
              VEYRA LIVE - TUI RECOVERY
=========================================================
The graphical Calamares installer is unavailable.

This emergency path invokes Alpine's text-mode installer.
IMPORTANT: It installs a BASE ALPINE SYSTEM, not a complete
Veyra desktop. Veyra's Calamares desktop selection, signed
packages, and hardware setup are NOT performed automatically.

For a complete Veyra installation, reboot and use Calamares.
Never select a disk containing data you want to preserve.
=========================================================
BANNER
printf 'Type ALPINE to proceed, or anything else to cancel: '
IFS= read -r answer || exit 1
[ "$answer" = ALPINE ] || { echo "Cancelled."; exit 0; }
exec setup-alpine
