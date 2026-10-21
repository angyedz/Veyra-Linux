#!/usr/bin/env python3
"""Real Veyra ext4 BIOS A -> B -> A boot test on ONE disposable qcow2 disk.

Uses the same live ISO, disk installer shell process, Alpine mkinitfs, GRUB
and installed OpenRC as the conventional E2E test. No host partition touched.
This is NOT a graphical Calamares click test or an OTA security signoff.
"""
import argparse
import base64
import importlib.util
import pathlib
import shutil
import subprocess
import sys
import tempfile

import pexpect

HERE = pathlib.Path(__file__).resolve().parent
PROJECT = HERE.parent
spec = importlib.util.spec_from_file_location("veyra_installer_e2e",
                                             HERE / "test-installed-qemu.py")
installed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installed)


def guest_cycle(qemu, disk, logdir, expected, commands):
    with (logdir / f"veyra-atomic-boot-{expected}.log").open("w") as stream:
        child = installed.boot(qemu, str(disk), None, stream, 400, installed=True)
        try:
            installed.login(child, 300)
            installed.run_command(child,
                                  f'test "$(cat /etc/veyra/deployment-id)" = "{expected}"', 30)
            installed.run_command(child,
                                  'test "$(cat /etc/veyra/deployment-mode)" = atomic-v1', 30)
            installed.run_command(child,
                                  'mountpoint -q /var/lib/veyra/store && '
                                  'mountpoint -q /home && mountpoint -q /nix', 30)
            installed.run_command(child,
                                  f'test "$(cat /var/lib/veyra/store/deployments/{expected}/'
                                  f'etc/veyra/deployment-id)" = "{expected}"', 30)
            for command in commands:
                installed.run_command(child, command, 60)
            installed.run_command(child, "sync", 30)
            # Shut the disposable guest down after its writes are durable so
            # QEMU exits on its own instead of leaving a live emulator for
            # pexpect's forced-termination path.
            child.sendline("poweroff")
            try:
                child.expect(installed.pexpect.EOF, timeout=90)
            except installed.pexpect.EOF:
                pass
        finally:
            child.close(force=child.isalive())


def failed_candidate_boot(qemu, disk, logdir):
    """Fail B after initramfs arms A as the next GRUB default."""
    with (logdir / "veyra-atomic-boot-failed-B.log").open("w") as stream:
        child = installed.boot(qemu, str(disk), None, stream, 240, installed=True)
        try:
            child.expect("Veyra: fallback to A armed for next reboot", timeout=240)
            child.expect("VEYRA_TEST_CANDIDATE_INIT_FAILURE", timeout=60)
            child.expect("Kernel panic", timeout=60)
            print("Candidate B failed after rollback fallback was durably armed", flush=True)
        finally:
            child.close(force=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("iso", type=pathlib.Path)
    parser.add_argument("--log-dir", type=pathlib.Path, default=pathlib.Path("e2e-logs"))
    args = parser.parse_args()
    args.log_dir.mkdir(parents=True, exist_ok=True)
    qemu = shutil.which("qemu-system-x86_64")
    qimg = shutil.which("qemu-img")
    if not qemu or not qimg or not args.iso.is_file():
        parser.error("QEMU, qemu-img and a valid cached Veyra ISO are required")
    with tempfile.TemporaryDirectory(prefix="veyra-atomic-e2e-") as workspace:
        disk = pathlib.Path(workspace) / "atomic-test.qcow2"
        subprocess.run([qimg, "create", "-f", "qcow2", str(disk), "22G"], check=True)
        with (args.log_dir / "veyra-atomic-install.log").open("w") as stream:
            child = installed.boot(qemu, str(disk), str(args.iso.resolve()), stream, 400)
            try:
                installed.login(child, 360)
                for name in (
                    "installer-copy.sh", "installer-prepare.sh",
                    "installer-desktop.sh", "installer-hardware.sh",
                    "setup-pkgrepo.sh",
                    "veyra-deployment.sh", "veyra-initramfs-select.sh",
                    "build-veyra-init.sh", "veyra-atomic-convert.sh",
                    "veyra-bootctl.py", "veyra-boot-confirm.initd",
                ):
                    installed.upload_script(
                        child, (PROJECT / "scripts" / name).read_bytes(),
                        "/usr/local/lib/veyra/" + name)
                installed.upload_script(child, installed.install_script("plasma").encode(),
                                        "/tmp/e2e-install.sh")
                installed.run_command(child, "sh /tmp/e2e-install.sh", timeout=1500)
                # The non-atomic live ISO intentionally has no Python
                # requirement; the experimental boot coordinator is Python 3.
                installed.run_command(child, "apk add --no-cache python3", timeout=240)
                # The installer has finished writing and the root is mounted
                # but is not executing as the active guest root.
                installed.run_command(
                    child,
                    "VEYRA_ATOMIC_TEST_SERIAL=1 sh "
                    "/usr/local/lib/veyra/veyra-atomic-convert.sh /mnt/veyra-e2e",
                    timeout=1200)
                installed.run_command(
                    child,
                    "sh /usr/local/lib/veyra/veyra-deployment.sh "
                    "stage /mnt/veyra-e2e A B",
                    timeout=1200)
                installed.run_command(
                    child,
                    "test -s /mnt/veyra-e2e/deployments/A/boot/initramfs-lts && "
                    "test -s /mnt/veyra-e2e/deployments/B/boot/initramfs-lts && "
                    "test -d /mnt/veyra-e2e/deployments/A/run && "
                    "test -d /mnt/veyra-e2e/deployments/B/run && "
                    "test -d /mnt/veyra-e2e/deployments/A/tmp && "
                    "test -d /mnt/veyra-e2e/deployments/B/tmp && "
                    "test -f /mnt/veyra-e2e/boot-state/legacy-grub.cfg && "
                    "grep -q 'veyra_deployment=A' /mnt/veyra-e2e/boot/grub/grub.cfg && "
                    "grep -Fq '# VEYRA_DEFAULT=A' /mnt/veyra-e2e/boot/grub/grub.cfg && "
                    "! grep -q 'veyra_deployment=B' /mnt/veyra-e2e/boot/grub/grub.cfg",
                    timeout=45)
                installed.run_command(child, "sync", 30)
                # The live guest is still running here. Request shutdown and
                # wait for QEMU to exit before closing the PTY and disk.
                child.sendline("poweroff")
                try:
                    child.expect(installed.pexpect.EOF, timeout=90)
                except installed.pexpect.EOF:
                    pass
            finally:
                child.close(force=child.isalive())

        print("Atomically prepared A/B on disposable installed ext4 disk; booting A",
              flush=True)
        guest_cycle(qemu, disk, args.log_dir, "A", [
            "echo 'data created in A' > /home/e2euser/atomic-data.txt",
            "rm -f /var/lib/veyra/store/deployments/B/sbin/init",
            "printf '#!/bin/sh\\necho VEYRA_TEST_CANDIDATE_INIT_FAILURE\\nexit 1\\n' "
            "> /var/lib/veyra/store/deployments/B/sbin/init",
            "chmod 0755 /var/lib/veyra/store/deployments/B/sbin/init",
            "/usr/local/sbin/veyra-bootctl "
            "--store /var/lib/veyra/store activate B",
        ])
        print("Booting a deliberately broken B candidate", flush=True)
        failed_candidate_boot(qemu, disk, args.log_dir)
        print("Checking fallback to A and retrying a repaired B candidate", flush=True)
        guest_cycle(qemu, disk, args.log_dir, "A", [
            "grep -q '# VEYRA_DEFAULT=A' /var/lib/veyra/store/boot/grub/grub.cfg",
            """test "$(cat /var/lib/veyra/store/boot-state/pending)" = 'B A'""",
            """test "$(cat /home/e2euser/atomic-data.txt)" = 'data created in A'""",
            "/usr/local/sbin/veyra-bootctl "
            "--store /var/lib/veyra/store rollback A",
            "rm -f /var/lib/veyra/store/deployments/B/sbin/init",
            "cp -a /var/lib/veyra/store/deployments/A/sbin/init "
            "/var/lib/veyra/store/deployments/B/sbin/init",
            "sync",
            "/usr/local/sbin/veyra-bootctl "
            "--store /var/lib/veyra/store activate B",
        ])
        print("Booting repaired B from its own Alpine+Plasma system tree", flush=True)
        guest_cycle(qemu, disk, args.log_dir, "B", [
            """test "$(cat /home/e2euser/atomic-data.txt)" = 'data created in A'""",
            "grep -q '# VEYRA_DEFAULT=B' /var/lib/veyra/store/boot/grub/grub.cfg",
            "test ! -e /var/lib/veyra/store/boot-state/pending",
            "echo 'data updated in B' > /home/e2euser/atomic-data.txt",
            "printf 'only-B\\n' > /etc/veyra/slot-specific.txt",
            "test ! -e /var/lib/veyra/store/deployments/A/etc/veyra/slot-specific.txt",
            "/usr/local/sbin/veyra-bootctl "
            "--store /var/lib/veyra/store rollback A",
        ])
        print("Booting rolled-back A and checking durable user data", flush=True)
        guest_cycle(qemu, disk, args.log_dir, "A", [
            """test "$(cat /home/e2euser/atomic-data.txt)" = 'data updated in B'""",
            "test ! -e /etc/veyra/slot-specific.txt",
            "/usr/local/sbin/veyra-bootctl --store /var/lib/veyra/store status",
        ])
        print("VEYRA_ATOMIC_QEMU_SUCCESS: A -> failed B -> A fallback -> confirmed B -> A rollback, data survived",
              flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"VEYRA_ATOMIC_QEMU_FAILED: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
