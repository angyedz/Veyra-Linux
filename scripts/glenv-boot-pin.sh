#!/bin/sh
# Opt-in early-boot glenv generation selection for a future atomic Veyra host.
# Does not mount namespaces, install packages or change the active host slot.
set -eu

[ "$(id -u)" -eq 0 ] || {
    echo 'glenv boot pin requires root in the host boot environment' >&2
    exit 1
}

deployment_file=${VEYRA_DEPLOYMENT_ID_FILE:-/etc/veyra/deployment-id}
store=${VEYRA_GLENV_STORE:-/var/lib/veyra/glenv}
pin=${VEYRA_GLENV_PIN:-/run/glenv/selected}
glenv_bin=${VEYRA_GLENV_BIN:-/usr/local/lib/veyra/glenv-manager}

[ -f "$deployment_file" ] || {
    echo "Missing trusted Veyra deployment ID file: $deployment_file" >&2
    exit 1
}
deployment=$(cat "$deployment_file")
if ! printf '%s\n' "$deployment" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
    echo "Invalid Veyra deployment ID: $deployment_file" >&2
    exit 1
fi
[ -d "$store/versions" ] || {
    echo "Missing glenv version store: $store" >&2
    exit 1
}
case "$pin" in
    /*) : ;;
    *) echo "Boot pin path must be absolute: $pin" >&2; exit 1 ;;
esac

# An explicitly requested signed boot must NEVER fall back to unsigned
# selection. The trusted key must come from Veyra's independently authenticated
# host deployment, not from the glenv release or user environment.
require_signature=${VEYRA_GLENV_REQUIRE_SIGNATURE:-0}
case "$require_signature" in
    0|1) : ;;
    *) echo 'VEYRA_GLENV_REQUIRE_SIGNATURE must be 0 or 1' >&2; exit 1 ;;
esac

if [ "$require_signature" = 1 ]; then
    trusted_key=${VEYRA_GLENV_TRUST_KEY:-/etc/veyra/trust/glenv-ed25519.pub}
    case "$trusted_key" in
        /*) : ;;
        *) echo 'Trusted glenv key path must be absolute' >&2; exit 1 ;;
    esac
    candidate=$trusted_key
    while [ "$candidate" != / ]; do
        [ ! -L "$candidate" ] || {
            echo "Symlink in trusted glenv key path: $candidate" >&2
            exit 1
        }
        candidate=$(dirname "$candidate")
    done
    [ -f "$trusted_key" ] || {
        echo "Missing trusted glenv public key: $trusted_key" >&2
        exit 1
    }
    # Owner/mode tests are defense-in-depth; Veyra's boot coordinator must
    # additionally protect the key's parent directories and host metadata.
    [ "$(stat -c %u "$trusted_key")" = 0 ] || {
        echo 'Trusted glenv public key must be root-owned' >&2
        exit 1
    }
    permissions=$(stat -c %a "$trusted_key")
    case "$permissions" in
        ''|*[!0-7]*) echo 'Invalid trusted glenv key permissions' >&2; exit 1 ;;
    esac
    if [ $((0$permissions & 022)) -ne 0 ]; then
        echo 'Trusted glenv key must not be group/world writable' >&2
        exit 1
    fi
    "$glenv_bin" release --store "$store" boot-pair-pin-signed "$deployment" "$pin" "$trusted_key"
else
    # Legacy opt-in development path only; no signature authentication.
    "$glenv_bin" release --store "$store" boot-pair-pin "$deployment" "$pin"
fi
printf 'Pinned glenv for Veyra deployment %s at %s\n' "$deployment" "$pin"
