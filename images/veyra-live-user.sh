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
# SDDM autologin works through PAM without prompting for a password.
echo 'Veyra live user prepared.'
