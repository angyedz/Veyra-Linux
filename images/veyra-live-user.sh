#!/bin/sh
# Runs only in the diskless installer environment before SDDM starts.
set -eu
[ -r /etc/veyra-release ] || exit 0

# Xwayland needs a sticky socket directory in the writable live root before
# SDDM starts the Wayland Plasma session. Diskless roots may not inherit it.
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp /tmp/.X11-unix

if ! id veyra >/dev/null 2>&1; then
    adduser -D -h /home/veyra -s /bin/bash veyra
fi
for group in video audio input render wheel plugdev; do
    if grep -q "^$group:" /etc/group; then
        addgroup veyra "$group" 2>/dev/null || true
    fi
done
mkdir -p /home/veyra/Desktop /home/veyra/.config/autostart
if [ ! -f /home/veyra/.config/kwinrc ]; then
    cat > /home/veyra/.config/kwinrc <<'KWIN'
[Compositing]
Enabled=false
KWIN
fi
cat > /home/veyra/.config/autostart/veyra-plasma-watchdog.desktop <<'AUTOSTART'
[Desktop Entry]
Type=Application
Name=Veyra Plasma recovery
Comment=Restart the desktop shell if it exits
Exec=/usr/local/lib/veyra/plasma-watchdog.sh
Terminal=false
AUTOSTART
chown -R veyra:veyra /home/veyra
# SDDM autologin works through PAM without prompting for a password.
echo 'Veyra live user prepared.'
