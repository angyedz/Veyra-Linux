#!/bin/sh
# Static and negative tests. NEVER enter namespaces or pivot the actual root.
set -eu
repo=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
launcher="$repo/scripts/veyra-user-env-prototype.sh"
krunner="$repo/scripts/veyra-user-krunner.sh"
probe="$repo/tests/probe-dual-environment.sh"
for script in "$launcher" "$krunner" "$probe"; do sh -n "$script"; done
for token in 'id -u' 'unshare --user --map-root-user --mount --pid --ipc --net' \
    'mount --make-rprivate /' 'pivot_root . .veyra-old-root' \
    'umount -l /.veyra-old-root' 'mount -t proc proc /proc' \
    'exec /sbin/init' 'env -i' 'findmnt -rn -o TARGET'; do
    grep -Fq "$token" "$launcher" || { echo "Missing gate: $token" >&2; exit 1; }
done
grep -Fq '/proc/self/uid_map' "$krunner"
# This grep deliberately compares literal shell source, not a live expansion.
# shellcheck disable=SC2016
grep -Fq 'DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"' "$krunner"
grep -Fq 'system-kde' "$krunner"

if sh "$launcher" / >/dev/null 2>&1; then
    echo 'Host root accepted' >&2; exit 1
fi
if sh "$launcher" relative/path >/dev/null 2>&1; then
    echo 'Relative rootfs accepted' >&2; exit 1
fi
if sh "$krunner" --check >/dev/null 2>&1; then
    echo 'Host-side KRunner preflight erroneously passed' >&2; exit 1
fi

# Real rootless runner: exercise --check WITHOUT invoking unshare or mounts.
if [ "$(id -u)" -ne 0 ]; then
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT HUP INT TERM
    for dir in etc etc/init.d etc/runlevels sbin dev proc sys run tmp; do
        mkdir -p "$work/userroot/$dir"
    done
    printf '#!/bin/sh\nexit 0\n' > "$work/userroot/sbin/init"
    chmod 755 "$work/userroot/sbin/init"
    sh "$launcher" --check "$work/userroot" >/dev/null ||
        { echo 'Valid rootfs preflight failed' >&2; exit 1; }
    ln -s "$work/userroot" "$work/linked"
    if sh "$launcher" --check "$work/linked" >/dev/null 2>&1; then
        echo 'Symlinked rootfs accepted' >&2; exit 1
    fi
    mkdir "$work/incomplete"
    if sh "$launcher" --check "$work/incomplete" >/dev/null 2>&1; then
        echo 'Incomplete rootfs accepted' >&2; exit 1
    fi
    # Simulate a child mount below an otherwise ordinary rootfs directory:
    # -R alone misses this case because the parent is not a mountpoint.
    mkdir -p "$work/mock-bin"
    cat > "$work/mock-bin/findmnt" <<'MOCK'
#!/bin/sh
printf '%s\n' "$VEYRA_MOCK_MOUNT"
MOCK
    chmod 755 "$work/mock-bin/findmnt"
    if VEYRA_MOCK_MOUNT="$work/userroot/dev" \
       PATH="$work/mock-bin:$PATH" \
       sh "$launcher" --check "$work/userroot" >/dev/null 2>&1; then
        echo 'Nested mountpoint in rootfs accepted' >&2; exit 1
    fi
fi
echo 'PASS: experimental launcher and KRunner negative/preflight tests'
