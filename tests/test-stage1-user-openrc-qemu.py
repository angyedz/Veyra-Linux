#!/usr/bin/env python3
"""Exercise a system-side user-environment manager in two QEMU boots.

The system OpenRC default runlevel starts the manager and user environment;
a test-only serial getty autologs in as inner UID 1000. Each boot then checks
hostile rootfs metadata, manager lifecycle, PID 1 crash cleanup, and rootfs
persistence. The same ext4 disk is reused; this is a disposable prototype test only.
"""
import argparse
import pathlib
import shutil
import sys

import pexpect


def guest_boot(qemu, kernel, initramfs, user_disk, qemu_boot, logfile, system_root_disk=None):
    auto_count = (qemu_boot - 1) * 5 + 1
    first_count = auto_count + 1
    second_count = auto_count + 2
    final_count = auto_count + 3
    recovery_count = qemu_boot * 5
    disk_args = []
    if system_root_disk is not None:
        disk_args.extend([
            "-drive", f"file={system_root_disk.resolve()},if=virtio,format=raw,cache=writeback",
        ])
    disk_args.extend([
        "-drive", f"file={user_disk.resolve()},if=virtio,format=raw,cache=writeback",
    ])
    kernel_args = f"console=ttyS0,115200 panic=1 veyra_stage1_expect={qemu_boot}"
    if system_root_disk is not None:
        kernel_args += " veyra_stage1_dualroot=1"
    cmd = [
        "-machine", "q35,accel=tcg", "-m", "768", "-smp", "2",
        "-nodefaults", "-nographic", "-no-reboot",
        "-serial", "stdio", "-monitor", "none",
        "-kernel", str(kernel.resolve()),
        "-initrd", str(initramfs.resolve()),
        *disk_args,
        "-append", kernel_args,
    ]
    guest = pexpect.spawn(qemu, cmd, encoding=None, timeout=180)
    guest.logfile_read = logfile
    try:
        patterns = [
            b"VEYRA_STAGE1_SYSTEM_OPENRC_MANAGER_READY",
            f"VEYRA_STAGE1_AUTOLOGIN_PASS uid=1000 count={auto_count} host-run-isolated=1 manager-socket-isolated=1".encode(),
            b"VEYRA_STAGE1_ROOTFS_INODE_GUARD_PASS",
            b"VEYRA_STAGE1_ROOTFS_FD_BIND_SWAP_PASS",
            b"VEYRA_STAGE1_FD_SANITIZATION_PASS",
            b"VEYRA_STAGE1_PIDFD_STALE_SIGNAL_REJECTED",
            b"VEYRA_STAGE1_ROOTFS_REJECT_NESTED_MOUNT",
            b"VEYRA_STAGE1_ROOTFS_REJECT_UNMAPPED_OWNER",
            b"VEYRA_STAGE1_ROOTFS_REJECT_BLOCK_DEVICE",
            b"VEYRA_STAGE1_ROOTFS_REJECT_UNEXPECTED_SUID",
            b"VEYRA_STAGE1_ROOTFS_REJECT_INIT_ESCAPE",
            f"VEYRA_STAGE1_AUTOLOGIN_PASS uid=1000 count={first_count} host-run-isolated=1 manager-socket-isolated=1".encode(),
            b"VEYRA_STAGE1_STATUS_RUNNING ",
            b"VEYRA_STAGE1_STATUS_STOPPED",
            f"VEYRA_STAGE1_AUTOLOGIN_PASS uid=1000 count={second_count} host-run-isolated=1 manager-socket-isolated=1".encode(),
            f"VEYRA_STAGE1_LIFECYCLE_PASS boot={qemu_boot} starts=2 final-count={second_count} crash=detected".encode(),
            f"VEYRA_STAGE1_AUTOLOGIN_PASS uid=1000 count={final_count} host-run-isolated=1 manager-socket-isolated=1".encode(),
            f"VEYRA_STAGE1_MANAGER_DEATH_CLEANUP_PASS boot={qemu_boot} count={final_count} environment=stopped".encode(),
            f"VEYRA_STAGE1_MANAGER_RECOVERY_PASS state=RUNNING autologin-count={recovery_count} host-run-isolated=1 manager-socket-isolated=1 stale-socket=cleared".encode(),
            f"VEYRA_STAGE1_QEMU_SUCCESS: user environment lifecycle and persistence boot {qemu_boot}".encode(),
            b"VEYRA_STAGE1_FAILURE:",
            b"Kernel panic",
        ]
        if system_root_disk is not None:
            patterns.insert(1, b"VEYRA_STAGE1_SYSTEM_ROOT_EXT4_OPENRC_PASS")
        for expected_index in range(len(patterns) - 2):
            active_patterns = patterns if expected_index == 0 else patterns[1:]
            outcome = guest.expect(active_patterns, timeout=180)
            if expected_index != 0:
                outcome += 1
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
    parser.add_argument("--system-root-disk", type=pathlib.Path)
    parser.add_argument("--log", type=pathlib.Path,
                        default=pathlib.Path("veyra-stage1-qemu-serial.log"))
    args = parser.parse_args()
    qemu = shutil.which("qemu-system-x86_64")
    required_assets = [args.kernel, args.initramfs, args.user_disk]
    if args.system_root_disk is not None:
        required_assets.append(args.system_root_disk)
    if not qemu or not all(item.is_file() for item in required_assets):
        parser.error("QEMU, boot assets and disposable user-root disk are required")
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open("wb") as logfile:
        for qemu_boot in (1, 2):
            guest_boot(qemu, args.kernel, args.initramfs, args.user_disk,
                       qemu_boot, logfile, args.system_root_disk)
            print(f"VEYRA_STAGE1_QEMU_BOOT_{qemu_boot}_PASS", flush=True)
    print("VEYRA_STAGE1_LIFECYCLE_AND_PERSISTENCE_PASS: counts 5 then 10 including OpenRC autostart and recovery")
    if args.system_root_disk is not None:
        print("PASS: system OpenRC booted from a persistent ext4 disk root; user root is a second ext4 disk")
    print("NOTE: guest-only sudo fixture and manager; not installed Veyra security validation")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, pexpect.ExceptionPexpect) as error:
        print(f"VEYRA_STAGE1_TEST_FAIL: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
