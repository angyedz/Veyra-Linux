#!/bin/sh
# Runs only in the diskless installer environment before SDDM starts.
set -eu
[ -r /etc/veyra-release ] || exit 0

if ! id veyra >/dev/null 2>&1; then
    adduser -D -h /home/veyra -s /bin/bash veyra
fi
for group in video audio input render wheel plugdev; do
    if grep -q "^$group:" /etc/group; then
        addgroup veyra "$group" 2>/dev/null || true
    fi
done
mkdir -p /home/veyra/Desktop /home/veyra/.config
chown -R veyra:veyra /home/veyra
# Prepare the shared X11 socket directory for Plasma's Xwayland bridge.
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp /tmp/.X11-unix
# Alpine's SDDM OpenRC service waits for its logind runtime directory. Live
# autologin creates the Veyra user's directory, so prepare SDDM's as well.
sddm_uid=$(id -u sddm)
sddm_group=$(id -gn sddm)
mkdir -p "/run/user/$sddm_uid"
chown "sddm:$sddm_group" "/run/user/$sddm_uid"
chmod 0700 "/run/user/$sddm_uid"
# SDDM autologin works through PAM without prompting for a password.
echo 'Veyra live user prepared.'
