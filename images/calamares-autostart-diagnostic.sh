#!/bin/sh
# Diagnostic-only live ISO helper; this file is included only by an explicit
# VEYRA_TEST_CALAMARES_AUTOSTART=1 image build.
log=/tmp/veyra-calamares-autostart.log
wrapper_log=${XDG_CACHE_HOME:-$HOME/.cache}/veyra-calamares.log
# XDG autostart runs again if the live Plasma session is restarted. A live
# login may rebuild its home directory, so keep the boot-scoped lock in /tmp.
lock_dir=/tmp
if ! mkdir "$lock_dir/veyra-calamares-diagnostic.lock" 2>/dev/null; then
    exit 0
fi
serial_report() {
    printf '%s\n' "$1" | sudo -n tee -a /dev/ttyS0 >/dev/null
}
(
    printf '%s\n' 'VEYRA_DIAGNOSTIC_AUTOSTART: invoking installer wrapper' >>"$log"
    /usr/local/bin/veyra-install >>"$log" 2>&1
    status=$?
    printf 'VEYRA_DIAGNOSTIC_AUTOSTART: wrapper exited status=%s\n' "$status" >>"$log"
) >>"$log" 2>&1 &
wrapper_pid=$!

sleep 20
if pgrep -x calamares >/dev/null 2>&1; then
    serial_report 'VEYRA_DIAGNOSTIC_AUTOSTART: calamares process is running'
else
    serial_report 'VEYRA_DIAGNOSTIC_AUTOSTART: Calamares may still be starting'
fi
if [ -s "$log" ]; then
    tail -n 40 "$log" | sudo -n tee -a /dev/ttyS0 >/dev/null
else
    serial_report 'VEYRA_DIAGNOSTIC_AUTOSTART: wrapper log is empty'
fi
serial_report "VEYRA_DIAGNOSTIC_AUTOSTART: DISPLAY=${DISPLAY:-unset} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-unset} XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-unset}"
if [ -n "${XAUTHORITY:-}" ]; then
    serial_report "VEYRA_DIAGNOSTIC_AUTOSTART: XAUTHORITY=$XAUTHORITY readable=$([ -r "$XAUTHORITY" ] && echo yes || echo no)"
else
    serial_report 'VEYRA_DIAGNOSTIC_AUTOSTART: XAUTHORITY=unset'
fi
if [ -s "$wrapper_log" ]; then
    printf '%s\n' 'VEYRA_DIAGNOSTIC_AUTOSTART: Calamares wrapper log follows' \
        | sudo -n tee -a /dev/ttyS0 >/dev/null
    tail -n 60 "$wrapper_log" | sudo -n tee -a /dev/ttyS0 >/dev/null
    tail -n 0 -f "$wrapper_log" | sudo -n tee -a /dev/ttyS0 >/dev/null &
    tail_pid=$!
else
    serial_report 'VEYRA_DIAGNOSTIC_AUTOSTART: Calamares wrapper log is missing or empty'
    tail_pid=
fi
wait "$wrapper_pid"
wrapper_status=$?
if [ -n "$tail_pid" ]; then
    kill "$tail_pid" 2>/dev/null || true
fi
serial_report "VEYRA_DIAGNOSTIC_AUTOSTART: wrapper exited status=$wrapper_status"
