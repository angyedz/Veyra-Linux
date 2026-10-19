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
pin=${VEYRA_GLENV_PIN:-/run/glenv/runtime}
glenv_bin=${VEYRA_GLENV_BIN:-glenv}

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

# Fail closed: boot-pin verifies that the signed/selected host deployment ID
# matches an immutable per-deployment pair in the glenv version store. Authenticating the deployment
# ID itself is an external responsibility of Veyra's future boot coordinator.
"$glenv_bin" release --store "$store" boot-pair-pin "$deployment" "$pin"
printf 'Pinned glenv for Veyra deployment %s at %s\n' "$deployment" "$pin"
