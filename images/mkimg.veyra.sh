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
    kernel_cmdline="console=tty0 console=ttyS0,115200"
    syslinux_serial="0 115200"
    syslinux_timeout="50"
    # Alpine boots diskless: its writable root lives in RAM (tmpfs).
    # Kernel modules and offline package cache still use the boot medium.
    apks="$apks $(grep -vE '^[[:space:]]*(#|$)' images/packages-desktop.txt | tr '\n' ' ')"
}
