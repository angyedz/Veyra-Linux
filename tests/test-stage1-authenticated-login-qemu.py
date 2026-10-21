#!/usr/bin/env python3
"""Test a real password prompt and named login inside the managed QEMU rootfs."""
import argparse
import pathlib
import shutil
import sys

import pexpect


TEST_PASSWORD = b"Veyra-Stage1-QEMU-only!"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=pathlib.Path)
    parser.add_argument("initramfs", type=pathlib.Path)
    parser.add_argument("user_disk", type=pathlib.Path)
    parser.add_argument(
        "--log", type=pathlib.Path,
        default=pathlib.Path("veyra-stage1-auth-login-serial.log"),
    )
    args = parser.parse_args()

    qemu = shutil.which("qemu-system-x86_64")
    if not qemu or not all(path.is_file() for path in
                           (args.kernel, args.initramfs, args.user_disk)):
        parser.error("QEMU, initramfs, kernel and user-root disk are required")

    args.log.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "-machine", "q35,accel=tcg", "-m", "768", "-smp", "2",
        "-nodefaults", "-nographic", "-no-reboot",
        "-serial", "stdio", "-monitor", "none",
        "-kernel", str(args.kernel.resolve()),
        "-initrd", str(args.initramfs.resolve()),
        "-drive", f"file={args.user_disk.resolve()},if=virtio,format=raw,cache=writeback",
        "-append", "console=ttyS0,115200 panic=1",
    ]

    with args.log.open("wb") as logfile:
        guest = pexpect.spawn(qemu, command, encoding=None, timeout=180)
        guest.logfile_read = logfile
        try:
            guest.expect(b"VEYRA_STAGE1_AUTH_MANAGER_READY account=eve", timeout=120)
            guest.expect(b"login:", timeout=120)
            guest.sendline(b"eve")
            guest.expect(b"Password:", timeout=60)
            guest.sendline(b"not-the-test-password")
            outcome = guest.expect([
                b"Login incorrect",
                b"VEYRA_STAGE1_AUTHENTICATED_LOGIN_PASS account=eve uid=1000",
            ], timeout=60)
            if outcome != 0:
                raise RuntimeError("the guest accepted the wrong password")

            guest.expect(b"login:", timeout=60)
            guest.sendline(b"eve")
            guest.expect(b"Password:", timeout=60)
            guest.sendline(TEST_PASSWORD)
            guest.expect(
                b"VEYRA_STAGE1_AUTHENTICATED_LOGIN_PASS account=eve uid=1000",
                timeout=60,
            )
            guest.expect(
                b"VEYRA_STAGE1_AUTH_LOGIN_QEMU_SUCCESS account=eve uid=1000 outer-uid=101000",
                timeout=60,
            )
            guest.expect(pexpect.EOF, timeout=30)
        finally:
            guest.close(force=True)

    print(
        "VEYRA_STAGE1_AUTH_LOGIN_TEST_PASS: wrong password rejected; "
        "Eve authenticated in the managed rootfs as inner UID 1000"
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, pexpect.ExceptionPexpect) as error:
        print(f"VEYRA_STAGE1_AUTH_LOGIN_TEST_FAIL: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
