#!/bin/sh
# Boot an experimental Veyra ISO in QEMU and verify a login prompt appears.
set -eu
iso="${1:?usage: sh scripts/test-iso.sh path/to/veyra.iso [log-file]}"
log="${2:-veyra-boot.log}"

[ -f "$iso" ] || { echo "ISO not found: $iso" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || {
    echo 'qemu-system-x86_64 is required' >&2
    exit 1
}
command -v timeout >/dev/null || {
    echo 'GNU timeout is required' >&2
    exit 1
}

set +e
timeout "${VEYRA_BOOT_TIMEOUT:-120}" qemu-system-x86_64 \
    -machine accel=tcg -m 1024 -smp 2 \
    -display none -monitor none -serial stdio \
    -no-reboot -nic none -boot d -cdrom "$iso" > "$log" 2>&1
code=$?
set -e

# A timeout is expected: the live installer remains at an interactive prompt.
if [ "$code" -ne 0 ] && [ "$code" -ne 124 ]; then
    tail -n 100 "$log" >&2
    echo "QEMU exited with unexpected status $code" >&2
    exit 1
fi
if ! grep -aEq '(^|[[:space:]])login:|Welcome to Alpine Linux|Veyra Linux \(experimental\)' "$log"; then
    tail -n 120 "$log" >&2
    echo 'The guest did not reach an identifiable login banner.' >&2
    exit 1
fi
echo "Veyra ISO boot smoke passed (serial output: $log)"
