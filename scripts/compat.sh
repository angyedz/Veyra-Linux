#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || exit 1
apk add networkmanager networkmanager-openvpn networkmanager-openconnect networkmanager-wifi \
  dnsmasq elogind polkit wireguard-tools openvpn
rc-update add dbus default
rc-update add elogind default
rc-update add networkmanager default
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/90-dns.conf <<'CONF'
[main]
dns=dnsmasq
CONF
for svc in dbus elogind networkmanager; do rc-service "$svc" start || true; done
