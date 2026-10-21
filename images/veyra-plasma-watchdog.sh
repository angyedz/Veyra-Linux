#!/bin/sh
# Keep the live desktop usable if plasmashell exits during startup or later.
sleep 10
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}"
mkdir -p "$state_dir"
log="$state_dir/veyra-plasmashell.log"
delay=2

while :; do
    if pidof plasmashell >/dev/null 2>&1; then
        delay=2
        sleep 5
        continue
    fi

    printf '%s: plasmashell exited; restarting it\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$log"
    plasmashell --replace >> "$log" 2>&1 &
    sleep "$delay"
    if pidof plasmashell >/dev/null 2>&1; then
        delay=2
    elif [ "$delay" -lt 30 ]; then
        delay=$((delay * 2))
    else
        delay=30
    fi
done
