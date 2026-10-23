# shellcheck disable=SC2015 # Deliberate fail-closed conjunctions
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

    veyra_user_id=${KOPT_veyra_user_environment:-}
    case "$veyra_user_id" in
        '') ;;
        .*|*/*|*..*|*[!a-zA-Z0-9._-]*)
            echo "Veyra: invalid user environment ID: $veyra_user_id" >&2
            exit 1 ;;
        *) [ "${#veyra_user_id}" -le 64 ] || {
               echo 'Veyra: user environment ID too long' >&2
               exit 1
           } ;;
    esac
    veyra_pair_file="$sysroot/deployments/$veyra_id/etc/veyra/user-environment-id"
    if [ -L "$veyra_pair_file" ]; then
        echo 'Veyra: symlinked user environment selector' >&2
        exit 1
    fi
    if [ -e "$veyra_pair_file" ]; then
        [ -f "$veyra_pair_file" ] || {
            echo 'Veyra: invalid user environment selector' >&2
            exit 1
        }
        veyra_declared_user_id=$(cat "$veyra_pair_file") || {
            echo 'Veyra: cannot read user environment selector' >&2
            exit 1
        }
        [ -n "$veyra_user_id" ] && [ "$veyra_user_id" = "$veyra_declared_user_id" ] || {
            echo 'Veyra: selected user environment does not match system deployment' >&2
            exit 1
        }
        for veyra_rel in user-environments user-environments/"$veyra_user_id" \
            user-environments/"$veyra_user_id"/etc \
            user-environments/"$veyra_user_id"/etc/apk \
            user-environments/"$veyra_user_id"/etc/veyra \
            user-environments/"$veyra_user_id"/sbin; do
            [ ! -L "$sysroot/$veyra_rel" ] && [ -d "$sysroot/$veyra_rel" ] || {
                echo "Veyra: unsafe/missing $veyra_rel" >&2
                exit 1
            }
        done
        veyra_user_root="$sysroot/user-environments/$veyra_user_id"
        [ ! -L "$veyra_user_root/etc/apk/world" ] &&
            [ -f "$veyra_user_root/etc/apk/world" ] &&
            [ -s "$veyra_user_root/etc/apk/world" ] &&
            [ ! -L "$veyra_user_root/etc/veyra/user-environment-id" ] &&
            [ "$(cat "$veyra_user_root/etc/veyra/user-environment-id")" = "$veyra_user_id" ] || {
                echo 'Veyra: incomplete user environment metadata' >&2
                exit 1
            }
        veyra_user_init=$(readlink -f "$veyra_user_root/sbin/init") || {
            echo 'Veyra: user environment init is missing' >&2
            exit 1
        }
        case "$veyra_user_init" in
            "$veyra_user_root"/*) [ -f "$veyra_user_init" ] && [ -x "$veyra_user_init" ] || {
                echo 'Veyra: user environment init is not executable' >&2
                exit 1
            } ;;
            *) echo 'Veyra: user environment init escapes its root' >&2; exit 1 ;;
        esac
        for veyra_rel in var var/lib var/lib/veyra var/lib/veyra/user-root; do
            [ ! -L "$sysroot/deployments/$veyra_id/$veyra_rel" ] &&
                [ -d "$sysroot/deployments/$veyra_id/$veyra_rel" ] || {
                    echo "Veyra: unsafe/missing user root mountpoint $veyra_rel" >&2
                    exit 1
                }
        done
    elif [ -n "$veyra_user_id" ]; then
        echo 'Veyra: kernel selected a user environment absent from the system deployment' >&2
        exit 1
    fi

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
    if [ -n "$veyra_user_id" ]; then
        mount --bind "/media/veyra-store/user-environments/$veyra_user_id" \
            "$sysroot/var/lib/veyra/user-root" ||
            { echo 'Veyra: user environment bind failed' >&2; exit 1; }
    fi
    # The bind mounts keep the backing filesystem alive.
    # Do NOT leave the backing mount outside the switch_root destination.
    umount /media/veyra-store ||
        { echo 'Veyra: unable to release initramfs store mount' >&2; exit 1; }
    echo "Veyra: booting deployment $veyra_id${veyra_user_id:+ with user environment $veyra_user_id}"
fi
