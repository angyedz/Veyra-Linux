#!/usr/bin/env python3
"""Exercise a system-side user-environment manager in two QEMU boots.

Each boot validates hostile rootfs metadata, starts/statuses/stops the nested
init, restarts it, then kills that test PID 1 and expects crash detection. The
same persistent ext4 disk is reused; this is a disposable prototype test only.
"""
import argparse
import pathlib
import shutil
import sys

import pexpect


def guest_boot(qemu, kernel, initramfs, user_disk, qemu_boot, logfile):
    final_count = qemu_boot * 2
    cmd = [
        "-machine", "q35,accel=tcg", "-m", "768", "-smp", "2",
        "-nodefaults", "-nographic", "-no-reboot",
        "-serial", "stdio", "-monitor", "none",
        "-kernel", str(kernel.resolve()),
        "-initrd", str(initramfs.resolve()),
        "-drive", f"file={user_disk.resolve()},if=virtio,format=raw,cache=writeback",
        "-append", f"console=ttyS0,115200 panic=1 veyra_stage1_expect={qemu_boot}",
    ]
    guest = pexpect.spawn(qemu, cmd, encoding=None, timeout=180)
    guest.logfile_read = logfile
    try:
        patterns = [
            b"VEYRA_STAGE1_MANAGER_READY",
            b"VEYRA_STAGE1_ROOTFS_REJECT_NESTED_MOUNT",
            b"VEYRA_STAGE1_ROOTFS_REJECT_UNMAPPED_OWNER",
            b"VEYRA_STAGE1_ROOTFS_REJECT_BLOCK_DEVICE",
            b"VEYRA_STAGE1_ROOTFS_REJECT_UNEXPECTED_SUID",
            b"VEYRA_STAGE1_SUDO_READY inside-uid=0 outside-uid=100000",
            f"VEYRA_STAGE1_USER_OPENRC_READY count={final_count - 1}".encode(),
            b"VEYRA_STAGE1_STATUS_RUNNING ",
            b"VEYRA_STAGE1_STATUS_STOPPED",
            b"VEYRA_STAGE1_SUDO_READY inside-uid=0 outside-uid=100000",
            f"VEYRA_STAGE1_USER_OPENRC_READY count={final_count}".encode(),
            f"VEYRA_STAGE1_LIFECYCLE_PASS boot={qemu_boot} starts=2 final-count={final_count} crash=detected".encode(),
            f"VEYRA_STAGE1_QEMU_SUCCESS: user environment lifecycle and persistence boot {qemu_boot}".encode(),
            b"VEYRA_STAGE1_FAILURE:",
            b"Kernel panic",
        ]
        for expected_index in range(13):
            outcome = guest.expect(patterns, timeout=180)
            if outcome != expected_index:
                raise RuntimeError(
                    f"QEMU boot {qemu_boot} failed while waiting for stage {expected_index}; "
                    f"matched failure pattern {outcome}"
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
        for qemu_boot in (1, 2):
            guest_boot(qemu, args.kernel, args.initramfs, args.user_disk,
                       qemu_boot, logfile)
            print(f"VEYRA_STAGE1_QEMU_BOOT_{qemu_boot}_PASS", flush=True)
    print("VEYRA_STAGE1_LIFECYCLE_AND_PERSISTENCE_PASS: counts 2 then 4")
    print("NOTE: guest-only sudo fixture and manager; not installed Veyra security validation")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, pexpect.ExceptionPexpect) as error:
        print(f"VEYRA_STAGE1_TEST_FAIL: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
