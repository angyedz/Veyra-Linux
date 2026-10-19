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
            # Installed QEMU will be forcibly stopped after durable sync.
            # A real shutdown is also requested to exercise OpenRC cleanly.
            child.sendline("poweroff")
            try:
                child.expect("POWERED_OFF_TEST_SENTINEL_UNREACHABLE", timeout=25)
            except Exception:
                pass
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
                    "veyra-bootctl.py",
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
                    "test -f /mnt/veyra-e2e/boot-state/legacy-grub.cfg && "
                    "grep -q 'veyra_deployment=A' /mnt/veyra-e2e/boot/grub/grub.cfg && "
                    "grep -Fq '# VEYRA_DEFAULT=A' /mnt/veyra-e2e/boot/grub/grub.cfg && "
                    "! grep -q 'veyra_deployment=B' /mnt/veyra-e2e/boot/grub/grub.cfg",
                    timeout=45)
                installed.run_command(child, "sync", 30)
            finally:
                child.close(force=True)

        print("Atomically prepared A/B on disposable installed ext4 disk; booting A",
              flush=True)
        guest_cycle(qemu, disk, args.log_dir, "A", [
            "echo 'data created in A' > /home/e2euser/atomic-data.txt",
            "/usr/local/sbin/veyra-bootctl "
            "--store /var/lib/veyra/store activate B",
        ])
        print("Booting B from its own Alpine+Plasma system tree", flush=True)
        guest_cycle(qemu, disk, args.log_dir, "B", [
            """test "$(cat /home/e2euser/atomic-data.txt)" = 'data created in A'""",
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
        print("VEYRA_ATOMIC_QEMU_SUCCESS: A -> B -> A, persistent data survived",
              flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"VEYRA_ATOMIC_QEMU_FAILED: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
 /mnt/veyra-e2e/boot/grub/grub.cfg && "
                    "! grep -q 'veyra_deployment=B' /mnt/veyra-e2e/boot/grub/grub.cfg",
                    timeout=45)
                installed.run_command(child, "sync", 30)
            finally:
                child.close(force=True)

        print("Atomically prepared A/B on disposable installed ext4 disk; booting A",
              flush=True)
        guest_cycle(qemu, disk, args.log_dir, "A", [
            "echo 'data created in A' > /home/e2euser/atomic-data.txt",
            "/usr/local/sbin/veyra-bootctl "
            "--store /var/lib/veyra/store activate B",
        ])
        print("Booting B from its own Alpine+Plasma system tree", flush=True)
        guest_cycle(qemu, disk, args.log_dir, "B", [
            """test "$(cat /home/e2euser/atomic-data.txt)" = 'data created in A'""",
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
        print("VEYRA_ATOMIC_QEMU_SUCCESS: A -> B -> A, persistent data survived",
              flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"VEYRA_ATOMIC_QEMU_FAILED: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
