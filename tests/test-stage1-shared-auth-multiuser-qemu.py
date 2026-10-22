#!/usr/bin/env python3
"""Verify password login for two ordinary accounts in one managed user root."""
import argparse
import pathlib
import re
import shutil
import sys

import pexpect


ACCOUNTS = (
    (b"veyrauser", b"Veyra-account-one-test-only!", b"1000"),
    (b"veyrauser2", b"Veyra-account-two-test-only!", b"1001"),
)
LOGIN_PROMPT = re.compile(rb"login:\s*")


def login(child, account, password, count):
    child.expect(LOGIN_PROMPT, timeout=120)
    child.sendline(account)
    child.expect(b"Password:", timeout=30)
    child.sendline(password)
    marker = re.compile(
        rb"VEYRA_STAGE1_SHARED_AUTH_LOGIN_PASS account="
        + account
        + rb" uid="
        + count[0]
        + rb" count="
        + count[1]
        + rb" root=([^ ]+) apkdb=([^ ]+) mountns=([^ ]+) uidmap=([^\r\n ]+)"
    )
    child.expect(marker, timeout=45)
    fields = child.match.groups()
    child.sendline(b"exit")
    return fields


def reject_wrong_password(child, account):
    child.sendline(account)
    child.expect(b"Password:", timeout=30)
    child.sendline(b"incorrect-test-password")
    child.expect(b"Login incorrect", timeout=30)


def guest_boot(qemu, kernel, initramfs, user_disk, boot, logfile):
    command = [
        "-machine", "q35,accel=tcg", "-m", "768", "-smp", "2",
        "-nodefaults", "-nographic", "-no-reboot",
        "-serial", "stdio", "-monitor", "none",
        "-kernel", str(kernel.resolve()),
        "-initrd", str(initramfs.resolve()),
        "-drive", f"file={user_disk.resolve()},if=virtio,format=raw,cache=writeback",
        "-append", f"console=ttyS0,115200 panic=1 veyra_stage1_auth_expect={boot}",
    ]
    guest = pexpect.spawn(qemu, command, encoding=None, timeout=180)
    guest.logfile_read = logfile
    try:
        ready = False
        prompt_ready = False
        while not ready or not prompt_ready:
            outcome = guest.expect(
                [
                    f"VEYRA_STAGE1_SHARED_AUTH_MANAGER_READY boot={boot} accounts=1000,1001".encode(),
                    LOGIN_PROMPT,
                    b"VEYRA_STAGE1_SHARED_AUTH_FAILURE:",
                ],
                timeout=150,
            )
            if outcome == 0:
                ready = True
            elif outcome == 1:
                prompt_ready = True
            else:
                raise RuntimeError(f"guest reported an init failure during boot {boot}")
        shared_identity = None
        for account_index, (account, password, uid) in enumerate(ACCOUNTS):
            if account_index > 0:
                guest.expect(LOGIN_PROMPT, timeout=90)
            reject_wrong_password(guest, account)
            count = str(boot).encode()
            identity = login(guest, account, password, (uid, count))
            if shared_identity is None:
                shared_identity = identity
            elif identity != shared_identity:
                raise RuntimeError(
                    "the two authenticated accounts did not observe the same root, "
                    "APK database, mount namespace and UID map"
                )
            if account_index == 0:
                guest.expect(LOGIN_PROMPT, timeout=45)
            else:
                guest.expect(
                    f"VEYRA_STAGE1_SHARED_AUTH_MULTIUSER_PASS accounts=1000,1001 "
                    f"shared-root=1 shared-apkdb=1 shared-mountns=1 separate-homes=1 "
                    f"wrong-password-rejected=1 persistent-count={boot}".encode(),
                    timeout=90,
                )
                guest.expect(pexpect.EOF, timeout=30)
        guest.close(force=False)
        if guest.exitstatus != 0:
            raise RuntimeError(f"QEMU boot {boot} exited with status {guest.exitstatus}")
    finally:
        if not guest.closed:
            guest.close(force=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=pathlib.Path)
    parser.add_argument("initramfs", type=pathlib.Path)
    parser.add_argument("user_disk", type=pathlib.Path)
    parser.add_argument(
        "--log", type=pathlib.Path,
        default=pathlib.Path("veyra-stage1-shared-auth-multiuser-serial.log"),
    )
    args = parser.parse_args()

    qemu = shutil.which("qemu-system-x86_64")
    if not qemu or not all(path.is_file() for path in
                           (args.kernel, args.initramfs, args.user_disk)):
        parser.error("QEMU, kernel, initramfs and user-root disk are required")

    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open("wb") as logfile:
        for boot in (1, 2):
            guest_boot(qemu, args.kernel, args.initramfs, args.user_disk, boot, logfile)
            print(f"VEYRA_STAGE1_SHARED_AUTH_QEMU_BOOT_{boot}_PASS", flush=True)
    print(
        "PASS: two ordinary Linux accounts rejected bad passwords, authenticated "
        "inside the same managed root, used separate homes and retained per-account state across two boots"
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, pexpect.ExceptionPexpect) as error:
        print(f"VEYRA_STAGE1_SHARED_AUTH_QEMU_FAIL: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
