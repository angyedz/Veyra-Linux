#!/usr/bin/env python3
"""Real Veyra ext4 BIOS trial-confirmation/fallback test on ONE disposable disk.

Uses the same live ISO, disk installer shell process, Alpine mkinitfs, GRUB
and installed OpenRC as the conventional E2E test. No host partition touched.
This is NOT a graphical Calamares click test or an OTA security signoff.
It proves A -> confirmed B -> unconfirmed C -> automatic fallback B -> rollback A.
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
            for step in commands:
                if isinstance(step, tuple):
                    command, timeout = step
                else:
                    command, timeout = step, 60
                installed.run_command(child, command, timeout)
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


def expect_injected_trial_failure(qemu, disk, logdir):
    log_path = logdir / "veyra-atomic-failed-trial-C.log"
    with log_path.open("w") as stream:
        child = installed.boot(qemu, str(disk), None, stream, 400, installed=True)
        try:
            # The QEMU helper uses -no-reboot, so the deliberate guest reboot
            # terminates this process. The following guest_cycle boots fallback B.
            child.expect(pexpect.EOF, timeout=360)
        except pexpect.TIMEOUT as error:
            raise RuntimeError("injected trial failure did not reboot the QEMU guest") from error
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
                installed.upload_script(
                    child, (HERE / "veyra-trial-failure.initd").read_bytes(),
                    "/usr/local/lib/veyra/veyra-trial-failure.initd")
                installed.upload_script(child, installed.install_script("plasma").encode(),
                                        "/tmp/e2e-install.sh")
                installed.run_command(child, "sh /tmp/e2e-install.sh", timeout=1500)
                # The live AppCenter package already depends on python3. Verify
                # the conversion helper can use it without opening an APK
                # transaction against the live ISO's temporary package world.
                installed.run_command(
                    child, "command -v python3 >/dev/null || exit 1", timeout=30)
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
            finally:
                child.close(force=True)

        print("Atomically prepared A/B on disposable installed ext4 disk; booting A",
              flush=True)
        guest_cycle(qemu, disk, args.log_dir, "A", [
            "grub-editenv /var/lib/veyra/store/boot/grub/grubenv list | "
            "grep -Fqx saved_entry=veyra-A",
            "echo 'data created in A' > /home/e2euser/atomic-data.txt",
            "/usr/local/sbin/veyra-bootctl "
            "--store /var/lib/veyra/store activate B",
        ])
        print("Booting B from its own Alpine+Plasma system tree", flush=True)
        guest_cycle(qemu, disk, args.log_dir, "B", [
            """test "$(cat /home/e2euser/atomic-data.txt)" = 'data created in A'""",
            "grub-editenv /var/lib/veyra/store/boot/grub/grubenv list | "
            "grep -Fqx saved_entry=veyra-B",
            "echo 'data updated in B' > /home/e2euser/atomic-data.txt",
            "printf 'only-B\\n' > /etc/veyra/slot-specific.txt",
            "test ! -e /var/lib/veyra/store/deployments/A/etc/veyra/slot-specific.txt",
            ("/usr/local/lib/veyra/veyra-deployment.sh stage "
             "/var/lib/veyra/store B C", 1200),
            "install -m755 /usr/local/lib/veyra/veyra-trial-failure.initd "
            "/var/lib/veyra/store/deployments/C/etc/init.d/veyra-trial-failure",
            "ln -s /etc/init.d/veyra-trial-failure "
            "/var/lib/veyra/store/deployments/C/etc/runlevels/default/veyra-trial-failure",
            "/usr/local/sbin/veyra-bootctl --store /var/lib/veyra/store activate C",
        ])
        print("Injecting failure during trial C; expecting automatic fallback to B",
              flush=True)
        expect_injected_trial_failure(qemu, disk, args.log_dir)
        guest_cycle(qemu, disk, args.log_dir, "B", [
            "grub-editenv /var/lib/veyra/store/boot/grub/grubenv list | "
            "grep -Fqx saved_entry=veyra-B",
            "if grub-editenv /var/lib/veyra/store/boot/grub/grubenv list | grep -q '^next_entry='; then exit 1; fi",
            "test \"$(cat /var/lib/veyra/store/boot-state/trial-failed)\" = C",
            "test \"$(cat /etc/veyra/slot-specific.txt)\" = only-B",
            "test \"$(cat /home/e2euser/atomic-data.txt)\" = 'data written by failed C'",
            "/usr/local/sbin/veyra-bootctl --store /var/lib/veyra/store rollback A",
        ])
        print("Booting explicitly rolled-back A and checking durable user data", flush=True)
        guest_cycle(qemu, disk, args.log_dir, "A", [
            """test "$(cat /home/e2euser/atomic-data.txt)" = 'data written by failed C'""",
            "test ! -e /etc/veyra/slot-specific.txt",
            "grub-editenv /var/lib/veyra/store/boot/grub/grubenv list | "
            "grep -Fqx saved_entry=veyra-A",
        ])
        print("VEYRA_ATOMIC_QEMU_SUCCESS: A -> confirmed B -> failed trial C -> fallback B -> rollback A",
              flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"VEYRA_ATOMIC_QEMU_FAILED: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
