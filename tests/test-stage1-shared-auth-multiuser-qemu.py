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


def identity_pattern(account, uid, count):
    # pexpect scans a stream, not a completed line. Without an explicit
    # newline it may match '655' before the remaining '36' arrives.
    return re.compile(
        rb"VEYRA_STAGE1_SHARED_AUTH_LOGIN_PASS account="
        + account
        + rb" uid="
        + uid
        + rb" count="
        + count
        + rb" root=([^ ]+) apkdb=([^ ]+) mountns=([^ ]+) uidmap=([^\r\n ]+)\r?\n"
    )


def parser_selftest():
    marker = identity_pattern(b"veyrauser", b"1000", b"2")
    partial = (b"VEYRA_STAGE1_SHARED_AUTH_LOGIN_PASS account=veyrauser "
               b"uid=1000 count=2 root=64768:2 apkdb=64768:301 "
               b"mountns=mnt:[4026532158] uidmap=0:100000:655")
    if marker.search(partial) is not None:
        raise RuntimeError("streaming UID mapping prefix was accepted")
    complete = partial + b"36\r\n"
    matched = marker.search(complete)
    if matched is None or matched.groups()[-1] != b"0:100000:65536":
        raise RuntimeError("completed UID mapping line was not matched")
    if marker.search(complete.replace(b"uid=1000", b"uid=1001")) is not None:
        raise RuntimeError("wrong account identity matched")
    print("VEYRA_STAGE1_AUTH_SERIAL_PARSER_PASS", flush=True)


def login(child, account, password, count):
    child.expect(LOGIN_PROMPT, timeout=120)
    child.sendline(account)
    child.expect(b"Password:", timeout=30)
    child.sendline(password)
    marker = identity_pattern(account, count[0], count[1])
    child.expect(marker, timeout=45)
    fields = child.match.groups()
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
            # The boot-readiness loop consumes the first login prompt; after
            # each successful profile, the branch below consumes the next.
            # Do not wait for another prompt here or the second account stalls
            # until the guest's bounded authentication window expires.
            reject_wrong_password(guest, account)
            count = str(boot).encode()
            identity = login(guest, account, password, (uid, count))
            if shared_identity is None:
                shared_identity = identity
            elif identity != shared_identity:
                raise RuntimeError(
                    "the two authenticated accounts did not observe the same root, "
                    "APK database, mount namespace and UID map: "
                    f"first={shared_identity!r}, second={identity!r}"
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
    if sys.argv[1:] == ["--check-parser"]:
        parser_selftest()
        return
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
