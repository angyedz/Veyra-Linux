#!/usr/bin/env python3
"""Verify real user namespaces in a diskless, networkless Alpine QEMU guest."""
import argparse
import pathlib
import shutil
import sys
import pexpect


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=pathlib.Path)
    parser.add_argument("initramfs", type=pathlib.Path)
    parser.add_argument("--log", type=pathlib.Path,
                        default=pathlib.Path("userns-qemu-serial.log"))
    args = parser.parse_args()
    qemu = shutil.which("qemu-system-x86_64")
    if not qemu or not args.kernel.is_file() or not args.initramfs.is_file():
        parser.error("QEMU and kernel/initramfs required")
    args.log.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "-machine", "q35,accel=tcg", "-m", "512", "-smp", "2",
        "-nodefaults", "-nographic", "-no-reboot",
        "-serial", "stdio", "-monitor", "none",
        "-kernel", str(args.kernel.resolve()),
        "-initrd", str(args.initramfs.resolve()),
        "-append", "console=ttyS0,115200 panic=1",
    ]
    with args.log.open("wb") as logfile:
        guest = pexpect.spawn(qemu, command, encoding=None, timeout=150)
        guest.logfile_read = logfile
        try:
            result = guest.expect(
                [b"VEYRA_USERNS_QEMU_SUCCESS:",
                 b"VEYRA_USERNS_QEMU_FAILURE:",
                 b"Kernel panic"],
                timeout=150,
            )
            if result != 0:
                raise RuntimeError("guest failed namespace checks")
            print("PASS: rootless UID/PID/mount/network/IPC QEMU kernel primitives")
            print("NOTE: this is NOT a full Veyra user OpenRC or security test")
        finally:
            guest.close(force=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, pexpect.ExceptionPexpect) as error:
        print(f"VEYRA_USERNS_QEMU_FAILED: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
