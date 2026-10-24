#!/usr/bin/env python3
"""Boot the standalone Veyra Recovery initramfs under disposable QEMU.

The VM gets NO writable disks and NO network devices. The serial UI must
start without KDE, a deployment store or a conventional root filesystem.
"""
import argparse
import pathlib
import shutil
import sys

import pexpect


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=pathlib.Path)
    parser.add_argument("initramfs", type=pathlib.Path)
    parser.add_argument("--log", type=pathlib.Path, default=pathlib.Path("recovery-serial.log"))
    parser.add_argument("--expect-update-menu", action="store_true")
    args = parser.parse_args()
    qemu = shutil.which("qemu-system-x86_64")
    if not qemu or not args.kernel.is_file() or not args.initramfs.is_file():
        parser.error("QEMU, a kernel and a recovery initramfs are required")
    command = [
        "-machine", "q35,accel=tcg", "-m", "512",
        "-nographic", "-no-reboot", "-nodefaults",
        "-serial", "stdio", "-monitor", "none",
        "-kernel", str(args.kernel.resolve()),
        "-initrd", str(args.initramfs.resolve()),
        "-append", "console=ttyS0,115200 panic=1",
    ]
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open("wb") as log:
        guest = pexpect.spawn(qemu, command, timeout=150, encoding=None)
        guest.logfile_read = log
        try:
            guest.expect(b"VEYRA RECOVERY ENVIRONMENT", timeout=150)
            if args.expect_update_menu:
                guest.expect_exact(b"4) Apply a signed update to an offline Veyra store", timeout=30)
            else:
                guest.expect_exact(b"4) Reboot", timeout=30)
            guest.expect(b"Choice:", timeout=30)
            guest.sendline(b"2")
            guest.expect(b"console=ttyS0,115200", timeout=30)
            guest.expect(b"Choice:", timeout=30)
            guest.sendline(b"3")
            guest.expect(b"VEYRA-RECOVERY-v1", timeout=30)
            guest.expect(b"Choice:", timeout=30)
            guest.sendline(b"1")
            guest.expect(b"major", timeout=30)
            guest.expect(b"Choice:", timeout=30)
            if args.expect_update_menu:
                guest.sendline(b"4")
                guest.expect(b"Veyra store partition", timeout=30)
                guest.sendline(b"/dev/veyra-invalid-test-device")
                guest.expect(b"not a block device", timeout=30)
                guest.expect(b"Choice:", timeout=30)
                guest.sendline(b"4")
                guest.expect(b"Veyra store partition", timeout=30)
                guest.sendline(b"")
                guest.expect(b"Automatic detection found 0 verified Veyra stores", timeout=30)
                guest.expect(b"Choice:", timeout=30)
                print("VEYRA_RECOVERY_UPDATE_MENU_QEMU_SUCCESS: updater runtime detected and invalid disk rejected",
                      flush=True)
            # The expert shell must be explicitly authorized, must remain in
            # the independent initramfs, and must return to the rescue menu.
            shell_choice = b"7" if args.expect_update_menu else b"6"
            guest.sendline(shell_choice)
            guest.expect_exact(b"Type SHELL to continue", timeout=30)
            guest.sendline(b"no")
            guest.expect_exact(b"Recovery shell cancelled.", timeout=30)
            guest.expect(b"Choice:", timeout=30)
            guest.sendline(shell_choice)
            guest.expect_exact(b"Type SHELL to continue", timeout=30)
            guest.sendline(b"SHELL")
            guest.expect(b"[#] ", timeout=30)
            guest.sendline(b"cat /run/veyra/recovery-environment")
            guest.expect(b"VEYRA-RECOVERY-v1", timeout=30)
            guest.sendline(b"exit")
            guest.expect_exact(b"Returned to Veyra Recovery.", timeout=30)
            guest.expect(b"Choice:", timeout=30)
            print("VEYRA_RECOVERY_SHELL_QEMU_SUCCESS: explicit consent, independent shell and menu return", flush=True)
            print("VEYRA_RECOVERY_QEMU_SUCCESS: independent diskless serial boot", flush=True)
        finally:
            guest.close(force=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, pexpect.ExceptionPexpect) as error:
        print(f"VEYRA_RECOVERY_QEMU_FAILED: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
