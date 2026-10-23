#!/bin/sh
# Protect the intended KDE-first atomic system policy without changing ISO.
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
manifest="$root/deployment/plasma-system-packages.txt"
live="$root/images/packages-desktop.txt"
[ -s "$manifest" ] || { echo 'Missing Plasma system manifest' >&2; exit 1; }
[ -s "$live" ] || exit 1

packages=$(grep -vE '^[[:space:]]*(#|$)' "$manifest")
printf '%s\n' "$packages" | grep -qx plasma-desktop
printf '%s\n' "$packages" | grep -qx kwin
printf '%s\n' "$packages" | grep -qx plasma-workspace
printf '%s\n' "$packages" | grep -qx openrc-settingsd
printf '%s\n' "$packages" | grep -qx openrc-settingsd-openrc
printf '%s\n' "$packages" | grep -qx alpine-base
count=$(printf '%s\n' "$packages" | wc -l)
unique=$(printf '%s\n' "$packages" | sort -u | wc -l)
[ "$count" -eq "$unique" ] || { echo 'Duplicate system package' >&2; exit 1; }

for app in firefox konsole dolphin veyra-calamares nix; do
    if printf '%s\n' "$packages" | grep -qx "$app"; then
        echo "User or live-only app included in system deployment: $app" >&2
        exit 1
    fi
done

# All system package goals except alpine-base must already be available in
# today's proven Live ISO. No surprise package/ABI switch is implied.
printf '%s\n' "$packages" | while IFS= read -r package; do
    [ "$package" = alpine-base ] && continue
    grep -qx "$package" "$live" || {
        echo "Plasma system package not present in existing Live profile: $package" >&2
        exit 1
    }
done

# No accidental atomic boot changes in the conventional mkimage profile.
! grep -Eq '@deploy-|atomic-v1|subvolid=5' "$root/images/mkimg.veyra.sh" || {
    echo 'Conventional Live ISO must not enable atomic root layout' >&2
    exit 1
}
echo 'Plasma native system layer and conventional Live ISO boundary verified'
