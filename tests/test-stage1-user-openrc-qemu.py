#!/usr/bin/env python3
"""Boot two real QEMU guests against one persistent Alpine user rootfs disk.

System init mounts an ext4 rootfs, launches a separate user-namespace PID1,
and the user BusyBox init runs OpenRC. Does NOT prove production Veyra security,
sudo confinement, graphical KDE or installer integration.
"""
import argparse
import pathlib
import shutil
import sys

import pexpect


def guest_boot(qemu, kernel, initramfs, user_disk, count, logfile):
    cmd = [
        "-machine", "q35,accel=tcg", "-m", "768", "-smp", "2",
        "-nodefaults", "-nographic", "-no-reboot",
        "-serial", "stdio", "-monitor", "none",
        "-kernel", str(kernel.resolve()),
        "-initrd", str(initramfs.resolve()),
        "-drive", f"file={user_disk.resolve()},if=virtio,format=raw,cache=writeback",
        "-append", f"console=ttyS0,115200 panic=1 veyra_stage1_expect={count}",
    ]
    guest = pexpect.spawn(qemu, cmd, encoding=None, timeout=150)
    guest.logfile_read = logfile
    try:
        sudo_outcome = guest.expect([
            b"VEYRA_STAGE1_SUDO_READY inside-uid=0 outside-uid=100000",
            b"VEYRA_STAGE1_FAILURE:",
            b"VEYRA_STAGE1_QEMU_FAILURE:",
            b"Kernel panic",
        ], timeout=150)
        if sudo_outcome != 0:
            raise RuntimeError(f"inner sudo confinement failed on run {count}")
        outcome = guest.expect([
            f"VEYRA_STAGE1_USER_OPENRC_READY count={count}".encode(),
            b"VEYRA_STAGE1_FAILURE:",
            b"VEYRA_STAGE1_QEMU_FAILURE:",
            b"Kernel panic",
        ], timeout=150)
        if outcome != 0:
            raise RuntimeError(f"Alpine user OpenRC did not boot on run {count}")
        guest.expect(b"VEYRA_STAGE1_USER_STATE_SYNCED", timeout=20)
        guest.expect(
            f"VEYRA_STAGE1_QEMU_SUCCESS: user OpenRC persistent boot {count}".encode(),
            timeout=20,
        )
        try:
            guest.expect(pexpect.EOF, timeout=15)
        except pexpect.TIMEOUT:
            pass
    finally:
        guest.close(force=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=pathlib.Path)
    parser.add_argument("initramfs", type=pathlib.Path)
    parser.add_argument("user_disk", type=pathlib.Path)
    parser.add_argument("--log", type=pathlib.Path,
                        default=pathlib.Path("veyra-stage1-qemu-serial.log"))
    args = parser.parse_args()
    qemu = shutil.which("qemu-system-x86_64")
    if not qemu or not all(
        item.is_file() for item in (args.kernel, args.initramfs, args.user_disk)
    ):
        parser.error("QEMU, boot assets and disposable user-root disk are required")
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open("wb") as logfile:
        for expected in (1, 2):
            guest_boot(qemu, args.kernel, args.initramfs, args.user_disk,
                       expected, logfile)
            print(f"VEYRA_STAGE1_BOOT_{expected}_PASS", flush=True)
    print("VEYRA_STAGE1_PERSISTENCE_PASS: separate OpenRC and rootfs survived reboot")
    print("NOTE: guest-only inner sudo test, not installed Veyra sudo/VPN/KDE/security validation")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, pexpect.ExceptionPexpect) as error:
        print(f"VEYRA_STAGE1_TEST_FAIL: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
