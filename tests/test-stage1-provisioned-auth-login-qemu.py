#!/usr/bin/env python3
"""Authenticate the generic-manifest provisioned Eve root in disposable QEMU."""
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
    parser.add_argument("system_disk", type=pathlib.Path)
    parser.add_argument("user_store_disk", type=pathlib.Path)
    parser.add_argument("home_disk", type=pathlib.Path)
    parser.add_argument(
        "--log", type=pathlib.Path,
        default=pathlib.Path("veyra-stage1-manifest-auth-serial.log"),
    )
    args = parser.parse_args()

    qemu = shutil.which("qemu-system-x86_64")
    disks = (args.system_disk, args.user_store_disk, args.home_disk)
    if not qemu or not all(path.is_file() for path in
                           (args.kernel, args.initramfs, *disks)):
        parser.error("QEMU, initramfs, kernel and all three disks are required")

    args.log.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "-machine", "q35,accel=tcg", "-m", "768", "-smp", "2",
        "-nodefaults", "-nographic", "-no-reboot",
        "-serial", "stdio", "-monitor", "none",
        "-kernel", str(args.kernel.resolve()),
        "-initrd", str(args.initramfs.resolve()),
        "-drive", f"file={args.system_disk.resolve()},if=virtio,format=raw,cache=writeback",
        "-drive", f"file={args.user_store_disk.resolve()},if=virtio,format=raw,cache=writeback",
        "-drive", f"file={args.home_disk.resolve()},if=virtio,format=raw,cache=writeback",
        "-append", "console=ttyS0,115200 panic=1",
    ]

    with args.log.open("wb") as logfile:
        guest = pexpect.spawn(qemu, command, encoding=None, timeout=240)
        guest.logfile_read = logfile
        try:
            guest.expect(
                b"VEYRA_STAGE1_MANIFEST_AUTH_MANAGER_READY account=eve outer-uid-base=300000",
                timeout=210,
            )
            guest.expect(b"login:", timeout=90)
            guest.sendline(b"eve")
            guest.expect(b"Password:", timeout=45)
            guest.sendline(b"not-the-test-password")
            outcome = guest.expect(
                [
                    b"Login incorrect",
                    b"VEYRA_STAGE1_AUTHENTICATED_LOGIN_PASS account=eve uid=1000",
                ],
                timeout=45,
            )
            if outcome != 0:
                raise RuntimeError("the guest accepted the wrong password")

            guest.expect(b"login:", timeout=45)
            guest.sendline(b"eve")
            guest.expect(b"Password:", timeout=45)
            guest.sendline(TEST_PASSWORD)
            guest.expect(
                b"VEYRA_STAGE1_AUTHENTICATED_LOGIN_PASS account=eve uid=1000",
                timeout=45,
            )
            guest.expect(
                b"VEYRA_STAGE1_GENERIC_MANIFEST_AUTH_LOGIN_PASS account=eve outer-uid-base=300000 home-owner=301000",
                timeout=90,
            )
            guest.expect(pexpect.EOF, timeout=30)
        finally:
            guest.close(force=True)

    print(
        "VEYRA_STAGE1_PROVISIONED_AUTH_LOGIN_PASS: Eve came from the system account manifest, "
        "rejected a wrong password, authenticated as inner UID 1000, and wrote to a separate home volume"
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, pexpect.ExceptionPexpect) as error:
        print(f"VEYRA_STAGE1_PROVISIONED_AUTH_LOGIN_FAIL: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
