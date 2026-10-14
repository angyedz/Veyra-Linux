# Veyra Linux mkimage profile. Sourced by Alpine aports/scripts/mkimage.sh.
# shellcheck disable=SC2154
profile_veyra() {
    profile_standard
    title="Veyra Linux"
    desc="A lightweight and adaptable Alpine-based Linux system."
    profile_abbrev="veyra"
    image_name="veyra-linux"
    arch="x86_64"
    hostname="veyra"
    apkovl="images/genapkovl-veyra.sh"
    kernel_cmdline="console=tty0 console=ttyS0,115200"
    syslinux_serial="0 115200"
    apks="$apks bash curl git nano sudo ca-certificates dbus dbus-openrc
        networkmanager elogind polkit nix nix-openrc"
}
