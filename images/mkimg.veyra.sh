# Veyra Linux graphical live ISO profile. Sourced by Alpine mkimage.
# shellcheck disable=SC2154,SC2034
profile_veyra() {
    profile_standard
    title="Veyra Linux"
    desc="Minimal Plasma live ISO with Firefox, Konsole, Dolphin and installer."
    profile_abbrev="veyra"
    image_name="veyra-linux"
    arch="x86_64"
    hostname="veyra"
    apkovl="images/genapkovl-veyra.sh"
    kernel_cmdline="console=tty0 console=ttyS0,115200 rootflags=size=90%"
    syslinux_serial="0 115200"
    syslinux_timeout="50"
    # Alpine boots diskless: its writable root lives in RAM (tmpfs).
    # Kernel modules and offline package cache still use the boot medium.
    # Drop the legacy VLAN helper; NetworkManager handles networking.
    apks="$(printf '%s\n' "$apks" | tr ' ' '\n' | grep -vx network-extras | tr '\n' ' ')"
    apks="$apks $(grep -vE '^[[:space:]]*(#|$)' images/packages-desktop.txt | tr '\n' ' ')"

    # Replace Alpine's generic APK section with a versioned Veyra section.
    # This avoids reusing old, incomplete cached ISO repositories and lets us
    # reject a partial fetch before mkimage records the section as complete.
    all_sections=$(printf '%s\n' "${all_sections:-}" | tr ' ' '\n' | sed '/^apks$/d;/^$/d' | tr '\n' ' ')
}

# shellcheck disable=SC2153,SC2154
section_veyra_apks() {
    [ -n "$apks" ] || return 0

    # shellcheck disable=SC2086
    if ! _veyra_fetch_plan=$(apk fetch --timeout 30 --root "$APKROOT" --simulate --recursive $apks); then
        echo 'Unable to resolve the complete Veyra offline APK set.' >&2
        return 1
    fi
    _veyra_id=$(printf '%s\n' "$_veyra_fetch_plan" | sort | checksum)

    # The revision suffix intentionally invalidates generic cached sections
    # created before we verified every requested APK is present in the index.
    build_section veyra_apks "$ARCH" "offline-repo-v1-$_veyra_id"
}

# The standard apkovl cache key hashes only the generator script, even though
# it copies many additional files. Include those inputs so a helper-script
# change cannot silently reuse a stale live overlay.
section_apkovl() {
    [ -n "$apkovl" ] && [ -n "$hostname" ] || return 0
    _veyra_apkovl_id=$(
        find images branding scripts -type f -exec cksum '{}' \; |
            LC_ALL=C sort |
            checksum
    )
    build_section apkovl "$hostname" "veyra-apkovl-v2-$_veyra_apkovl_id"
}

# shellcheck disable=SC2153,SC2154
build_veyra_apks() {
    _veyra_apksdir="$DESTDIR/apks"
    _veyra_archdir="$_veyra_apksdir/$ARCH"
    _veyra_index_dump="$_veyra_archdir/.veyra-apkindex"
    mkdir -p "$_veyra_archdir"

    _veyra_fetched=no
    _veyra_attempt=1
    while [ "$_veyra_attempt" -le 3 ]; do
        # Package names in $apks intentionally split into separate apk arguments.
        # shellcheck disable=SC2086
        if timeout 120 apk fetch --timeout 30 --root "$APKROOT" --link --recursive --output "$_veyra_archdir" $apks; then
            _veyra_fetched=yes
            break
        fi

        echo "Veyra offline APK fetch attempt $_veyra_attempt failed; retrying incomplete downloads." >&2
        for _veyra_package_file in "$_veyra_archdir"/*.apk; do
            [ -f "$_veyra_package_file" ] || continue
            if ! tar -tzf "$_veyra_package_file" >/dev/null 2>&1; then
                rm -f "$_veyra_package_file"
            fi
        done
        _veyra_attempt=$((_veyra_attempt + 1))
    done
    if [ "$_veyra_fetched" != yes ]; then
        echo 'Failed to fetch the complete Veyra offline APK set.' >&2
        return 1
    fi
    if ! ls "$_veyra_archdir"/*.apk >/dev/null 2>&1; then
        echo 'Veyra offline APK repository contains no package archives.' >&2
        return 1
    fi

    apk index \
        --root "$APKROOT" \
        --description "$RELEASE" \
        --rewrite-arch "$ARCH" \
        --index "$_veyra_archdir/APKINDEX.tar.gz" \
        --output "$_veyra_archdir/APKINDEX.tar.gz" \
        "$_veyra_archdir"/*.apk || return 1
    abuild-sign "$_veyra_archdir/APKINDEX.tar.gz" || return 1
    tar -xOf "$_veyra_archdir/APKINDEX.tar.gz" APKINDEX > "$_veyra_index_dump" || return 1

    for _veyra_package_file in "$_veyra_archdir"/*.apk; do
        _veyra_package_name=$(tar -xOf "$_veyra_package_file" .PKGINFO | sed -n 's/^pkgname = //p' | head -n 1)
        if [ -z "$_veyra_package_name" ]; then
            echo "Unable to read package name from offline archive: $_veyra_package_file" >&2
            rm -f "$_veyra_index_dump"
            return 1
        fi
        if ! grep -Fqx "P:$_veyra_package_name" "$_veyra_index_dump"; then
            echo "Veyra offline APK index is missing package archive: $_veyra_package_name" >&2
            rm -f "$_veyra_index_dump"
            return 1
        fi
    done

    rm -f "$_veyra_index_dump"
    touch "$_veyra_apksdir/.boot_repository"
}
