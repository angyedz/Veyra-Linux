# This is SOURCED into Alpine's initramfs /init by build-veyra-init.sh.
# It executes ONLY when kernel cmdline contains veyra_deployment=<ID>.
# Alpine has already mounted root=UUID=<STORE> on "$sysroot".
# shellcheck disable=SC2154
if [ -n "${KOPT_veyra_deployment:-}" ]; then
    veyra_id=$KOPT_veyra_deployment
    # Refuse invalid kernel-supplied paths and refuse regular Alpine roots.
    case "$veyra_id" in
        ''|.*|*/*|*..*|*[!a-zA-Z0-9._-]*)
            echo "Veyra: invalid deployment ID: $veyra_id" >&2
            exit 1 ;;
    esac
    [ "${#veyra_id}" -le 64 ] || { echo 'Veyra: deployment ID too long' >&2; exit 1; }
    [ ! -L "$sysroot/.veyra-deployment-store" ] &&
        [ -f "$sysroot/.veyra-deployment-store" ] &&
        [ "$(cat "$sysroot/.veyra-deployment-store")" = VEYRA-DEPLOYMENT-STORE-v2 ] ||
        { echo 'Veyra: missing/invalid deployment store' >&2; exit 1; }
    for veyra_rel in deployments deployments/"$veyra_id" \
        deployments/"$veyra_id"/etc deployments/"$veyra_id"/etc/veyra \
        persistent persistent/home persistent/nix persistent/shared; do
        [ ! -L "$sysroot/$veyra_rel" ] &&
            [ -d "$sysroot/$veyra_rel" ] ||
            { echo "Veyra: unsafe/missing $veyra_rel" >&2; exit 1; }
    done
    [ ! -L "$sysroot/deployments/$veyra_id/etc/veyra/deployment-id" ] &&
        [ "$(cat "$sysroot/deployments/$veyra_id/etc/veyra/deployment-id")" = "$veyra_id" ] &&
        [ -f "$sysroot/deployments/$veyra_id/etc/apk/world" ] &&
        [ -x "$sysroot/deployments/$veyra_id/sbin/init" ] ||
        { echo "Veyra: incomplete deployment $veyra_id" >&2; exit 1; }

    # Use three independent bind mounts. No Btrfs or CoW assumptions.
    # The old filesystem is later accessible from /var/lib/veyra/store.
    mkdir -p /media/veyra-store
    mount --move "$sysroot" /media/veyra-store ||
        { echo 'Veyra: unable to relocate backing store' >&2; exit 1; }
    mount --bind "/media/veyra-store/deployments/$veyra_id" "$sysroot" ||
        { echo 'Veyra: unable to bind selected system root' >&2; exit 1; }
    mkdir -p "$sysroot/var/lib/veyra/store" "$sysroot/home" \
        "$sysroot/nix" "$sysroot/var/lib/veyra/shared"
    mount --bind /media/veyra-store "$sysroot/var/lib/veyra/store" ||
        { echo 'Veyra: store bind failed' >&2; exit 1; }
    mount --bind /media/veyra-store/persistent/home "$sysroot/home" ||
        { echo 'Veyra: home bind failed' >&2; exit 1; }
    mount --bind /media/veyra-store/persistent/nix "$sysroot/nix" ||
        { echo 'Veyra: Nix bind failed' >&2; exit 1; }
    mount --bind /media/veyra-store/persistent/shared "$sysroot/var/lib/veyra/shared" ||
        { echo 'Veyra: shared state bind failed' >&2; exit 1; }
    # The bind mounts keep the backing filesystem alive.
    # Do NOT leave the backing mount outside the switch_root destination.
    umount /media/veyra-store ||
        { echo 'Veyra: unable to release initramfs store mount' >&2; exit 1; }
    echo "Veyra: booting deployment $veyra_id"
fi
