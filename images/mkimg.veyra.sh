# Veyra Linux graphical live ISO profile. Sourced by Alpine mkimage.
# shellcheck disable=SC2154,SC2034
profile_veyra() {
    profile_standard
    title="Veyra Linux"
    desc="A fast and flexible Alpine-based KDE Plasma desktop."
    profile_abbrev="veyra"
    image_name="veyra-linux"
    arch="x86_64"
    hostname="veyra"
    apkovl="images/genapkovl-veyra.sh"
    kernel_cmdline="console=tty0 console=ttyS0,115200 rootflags=size=90%"
    syslinux_serial="0 115200"
    # Boot the default live entry automatically; PROMPT 1 leaves users at `boot:`.
    syslinux_prompt="0"
    syslinux_timeout="10"
    # Alpine boots diskless: its writable root lives in RAM (tmpfs).
    # Kernel modules and offline package cache still use the boot medium.
    # Drop the legacy VLAN helper; NetworkManager handles networking.
    apks="$(printf '%s\n' "$apks" | tr ' ' '\n' | grep -vx network-extras | tr '\n' ' ')"
    apks="$apks $(grep -vE '^[[:space:]]*(#|$)' images/packages-desktop.txt | tr '\n' ' ')"
    for package in vpkg veyra-glenv; do
        if [ -n "$(find packages/repo/x86_64 -maxdepth 1 -name "$package-*.apk" -print -quit 2>/dev/null)" ]; then
            apks="$apks $package"
        fi
    done
}
