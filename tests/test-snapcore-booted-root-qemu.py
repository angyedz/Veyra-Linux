#!/usr/bin/env python3
"""Boot, damage, and restore a real ext4 root exported by SnapCore."""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

import pexpect

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / "scripts" / "veyra-snapcore.py"
PLUGIN = ROOT / "tests" / "fixtures" / "snapcore-nbdkit-plugin.py"
VOLUME_SIZE = 32 * 1024 * 1024
ALPINE_VOLUME_SIZE = 256 * 1024 * 1024


def run_cli(store: pathlib.Path, command: str, *args: str) -> str:
    result = subprocess.run(
        [sys.executable, str(CLI), command, str(store), *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=120,
    )
    return result.stdout.strip()


def wait_for_socket(server: subprocess.Popen[bytes], socket: pathlib.Path) -> None:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if server.poll() is not None:
            raise RuntimeError(
                f"nbdkit exited during startup with status {server.returncode}"
            )
        if socket.exists():
            return
        time.sleep(0.05)
    raise TimeoutError("nbdkit did not create its Unix socket")


def kernel_nbd_size(device: pathlib.Path) -> int | None:
    result = subprocess.run(
        ["sudo", "-n", "blockdev", "--getsize64", str(device)],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
    )
    if result.returncode != 0 or not result.stdout.strip().isdigit():
        return None
    return int(result.stdout.strip())


def disconnect_kernel_nbd(qemu_nbd: str, device: pathlib.Path) -> None:
    result = subprocess.run(
        ["sudo", "-n", qemu_nbd, "--disconnect", str(device)],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"could not disconnect kernel NBD device {device}: {result.stdout.strip()}"
        )
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if kernel_nbd_size(device) == 0:
            return
        time.sleep(0.05)
    raise TimeoutError(f"kernel NBD device {device} stayed attached after disconnect")


def connect_kernel_nbd(
    qemu_nbd: str,
    socket: pathlib.Path,
    device: pathlib.Path,
    log_path: pathlib.Path,
    expected_size: int = VOLUME_SIZE,
) -> None:
    subprocess.run(["sudo", "-n", "modprobe", "nbd"], check=True, timeout=30)
    deadline = time.monotonic() + 15
    while not device.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    if not device.exists():
        raise RuntimeError(f"kernel NBD device was not created: {device}")
    if kernel_nbd_size(device) != 0:
        raise RuntimeError(f"kernel NBD device is already attached: {device}")

    with log_path.open("wb") as device_log:
        result = subprocess.run(
            [
                "sudo", "-n", qemu_nbd, "--connect", str(device),
                "--format=raw", f"nbd:unix:{socket}",
            ],
            check=False,
            stdout=device_log,
            stderr=subprocess.STDOUT,
            timeout=30,
        )
    if result.returncode != 0:
        details = log_path.read_text(errors="replace")
        raise RuntimeError(
            f"qemu-nbd attachment failed with status {result.returncode}: "
            f"{details[-4000:]}"
        )

    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        actual_size = kernel_nbd_size(device)
        if actual_size == expected_size:
            return
        if actual_size not in (None, 0):
            raise RuntimeError(
                f"{device} has unexpected size {actual_size}, expected {expected_size}"
            )
        time.sleep(0.05)
    details = log_path.read_text(errors="replace")
    raise TimeoutError(
        f"{device} did not become ready; qemu-nbd log: {details[-4000:]}"
    )


def guest_boot(
    qemu: str,
    qemu_nbd: str,
    kernel: pathlib.Path,
    initramfs: pathlib.Path,
    socket: pathlib.Path,
    device: pathlib.Path,
    phase: str,
    expected_marker: bytes,
    log_path: pathlib.Path,
    work: pathlib.Path,
    volume_size: int = VOLUME_SIZE,
) -> None:
    nbd_log = work / f"qemu-nbd-{phase}.log"
    connect_kernel_nbd(qemu_nbd, socket, device, nbd_log, volume_size)
    guest = None
    try:
        command = [
            "-machine", "q35,accel=tcg", "-m", "768", "-smp", "2",
            "-nodefaults", "-nographic", "-no-reboot",
            "-serial", "stdio", "-monitor", "none",
            "-kernel", str(kernel.resolve()),
            "-initrd", str(initramfs.resolve()),
            "-drive",
            f"file={device.resolve()},if=virtio,format=raw,cache=writeback",
            "-append",
            f"console=ttyS0,115200 panic=1 veyra_snapcore_phase={phase} "
            "veyra_snapcore_fixture=booted-root-test",
        ]
        guest = pexpect.spawn(
            "sudo", ["-n", qemu, *command], encoding=None, timeout=240
        )
        with log_path.open("ab") as serial_log:
            guest.logfile_read = serial_log
            outcome = guest.expect(
                [expected_marker, b"VEYRA_SNAPCORE_FAILURE:", b"Kernel panic"],
                timeout=240,
            )
            if outcome != 0:
                raise RuntimeError(
                    f"phase {phase} failed before its success marker "
                    f"(serial match {outcome})"
                )
            guest.expect(pexpect.EOF, timeout=30)
        guest.close()
        if guest.exitstatus not in (0, None):
            raise RuntimeError(f"phase {phase} QEMU exited with {guest.exitstatus}")
    finally:
        if guest is not None and guest.isalive():
            guest.close(force=True)
        disconnect_kernel_nbd(qemu_nbd, device)



def run_sudo(*args: str, timeout: int = 60) -> None:
    result = subprocess.run(
        ["sudo", "-n", *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"sudo command failed ({result.returncode}): {' '.join(args)}\n"
            f"{result.stdout[-4000:]}"
        )


def seed_alpine_ext4_root(
    qemu_nbd: str,
    socket: pathlib.Path,
    device: pathlib.Path,
    root: pathlib.Path,
    mountpoint: pathlib.Path,
    work: pathlib.Path,
) -> None:
    log_path = work / "qemu-nbd-alpine-seed.log"
    mountpoint.mkdir()
    connect_kernel_nbd(
        qemu_nbd, socket, device, log_path, ALPINE_VOLUME_SIZE
    )
    mounted = False
    try:
        run_sudo(
            "mkfs.ext4", "-F", "-q", "-L", "VEYRA_ALPINE_ROOT",
            str(device), timeout=120,
        )
        run_sudo("mount", str(device), str(mountpoint), timeout=30)
        mounted = True
        run_sudo("cp", "-a", f"{root.resolve()}/.", f"{mountpoint}/", timeout=120)
        run_sudo("sync", timeout=60)
    finally:
        try:
            if mounted:
                run_sudo("umount", str(mountpoint), timeout=60)
        finally:
            disconnect_kernel_nbd(qemu_nbd, device)

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=pathlib.Path)
    parser.add_argument("initramfs", type=pathlib.Path)
    parser.add_argument(
        "--alpine-root", type=pathlib.Path, required=True,
        help="Alpine/OpenRC root built by the initramfs builder",
    )
    parser.add_argument(
        "--log", type=pathlib.Path,
        default=pathlib.Path("snapcore-booted-root-qemu.log"),
    )
    args = parser.parse_args()
    qemu = shutil.which("qemu-system-x86_64")
    qemu_nbd = shutil.which("qemu-nbd")
    nbdkit = shutil.which("nbdkit")
    if (
        not qemu or not qemu_nbd or not nbdkit
        or not args.kernel.is_file() or not args.initramfs.is_file()
        or not args.alpine_root.is_dir()
    ):
        parser.error("QEMU, qemu-nbd, nbdkit, kernel and initramfs are required")

    args.log.parent.mkdir(parents=True, exist_ok=True)
    args.log.write_text("", encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="veyra-snapcore-booted-root-") as tmp:
        work = pathlib.Path(tmp)
        store = work / "snapcore-booted-root"
        socket = work / "snapcore-booted-root.sock"
        server_log_path = work / "nbdkit.log"
        device = pathlib.Path("/dev/nbd2")
        server = None
        try:
            run_cli(
                store, "format", "--size-bytes", str(VOLUME_SIZE),
                "--block-size", "4096",
            )
            with server_log_path.open("wb") as server_log:
                server = subprocess.Popen(
                    [
                        nbdkit, "-f", "-U", str(socket),
                        "python", str(PLUGIN), f"store={store}",
                    ],
                    stdout=server_log,
                    stderr=subprocess.STDOUT,
                )
            wait_for_socket(server, socket)

            guest_boot(
                qemu, qemu_nbd, args.kernel, args.initramfs, socket, device,
                "prepare-root", b"VEYRA_SNAPCORE_BOOTED_ROOT_BASELINE_PASS",
                args.log, work,
            )
            run_cli(store, "snapshot", "booted-ext4-root")
            status = json.loads(run_cli(store, "status"))
            if "booted-ext4-root" not in [
                item["name"] for item in status["snapshots"]
            ]:
                raise RuntimeError("SnapCore did not retain the booted ext4 root checkpoint")

            guest_boot(
                qemu, qemu_nbd, args.kernel, args.initramfs, socket, device,
                "mutate-root", b"VEYRA_SNAPCORE_BOOTED_ROOT_MUTATION_PASS",
                args.log, work,
            )
            run_cli(store, "rollback", "booted-ext4-root")
            run_cli(store, "verify")

            guest_boot(
                qemu, qemu_nbd, args.kernel, args.initramfs, socket, device,
                "verify-root", b"VEYRA_SNAPCORE_BOOTED_ROOT_RESTORE_PASS",
                args.log, work,
            )
            guest_boot(
                qemu, qemu_nbd, args.kernel, args.initramfs, socket, device,
                "delete-root", b"VEYRA_SNAPCORE_BOOTED_ROOT_FULL_DELETE_PASS",
                args.log, work,
            )
            run_cli(store, "rollback", "booted-ext4-root")
            run_cli(store, "verify")
            guest_boot(
                qemu, qemu_nbd, args.kernel, args.initramfs, socket, device,
                "verify-root", b"VEYRA_SNAPCORE_BOOTED_ROOT_RESTORE_PASS",
                args.log, work,
            )
            serial = args.log.read_bytes()
            if b"VEYRA_SNAPCORE_BOOTED_ROOT_E2FSCK_PASS" not in serial:
                raise RuntimeError("the restored ext4 root did not pass e2fsck")
            if b"VEYRA_SNAPCORE_BOOTED_ROOT_FULL_DELETE_PASS" not in serial:
                raise RuntimeError("the guest did not verify full root deletion")
            print("VEYRA_SNAPCORE_BOOTED_ROOT_QEMU_PASS")

            # Seed Alpine through the host kernel block frontend, then run its
            # BusyBox PID 1 and real OpenRC default service from the guest disk.
            alpine_store = work / "snapcore-alpine-openrc-root"
            alpine_socket = work / "snapcore-alpine-openrc.sock"
            alpine_server_log = work / "snapcore-alpine-nbdkit.log"
            alpine_server = None
            run_cli(
                alpine_store, "format", "--size-bytes", str(ALPINE_VOLUME_SIZE),
                "--block-size", "4096",
            )
            with alpine_server_log.open("wb") as alpine_server_log_file:
                alpine_server = subprocess.Popen(
                    [
                        nbdkit, "-f", "-U", str(alpine_socket),
                        "python", str(PLUGIN), f"store={alpine_store}",
                    ],
                    stdout=alpine_server_log_file,
                    stderr=subprocess.STDOUT,
                )
            try:
                wait_for_socket(alpine_server, alpine_socket)
                seed_alpine_ext4_root(
                    qemu_nbd, alpine_socket, device, args.alpine_root,
                    work / "alpine-openrc-mount", work,
                )
                guest_boot(
                    qemu, qemu_nbd, args.kernel, args.initramfs,
                    alpine_socket, device, "alpine-baseline",
                    b"VEYRA_SNAPCORE_ALPINE_BASELINE_PASS",
                    args.log, work, ALPINE_VOLUME_SIZE,
                )
                run_cli(alpine_store, "snapshot", "alpine-openrc-root")
                alpine_status = json.loads(run_cli(alpine_store, "status"))
                if "alpine-openrc-root" not in [
                    item["name"] for item in alpine_status["snapshots"]
                ]:
                    raise RuntimeError("SnapCore did not retain the Alpine/OpenRC checkpoint")
                guest_boot(
                    qemu, qemu_nbd, args.kernel, args.initramfs,
                    alpine_socket, device, "alpine-mutate",
                    b"VEYRA_SNAPCORE_ALPINE_MUTATION_PASS",
                    args.log, work, ALPINE_VOLUME_SIZE,
                )
                run_cli(alpine_store, "rollback", "alpine-openrc-root")
                run_cli(alpine_store, "verify")
                guest_boot(
                    qemu, qemu_nbd, args.kernel, args.initramfs,
                    alpine_socket, device, "alpine-verify",
                    b"VEYRA_SNAPCORE_ALPINE_RESTORE_PASS",
                    args.log, work, ALPINE_VOLUME_SIZE,
                )
                guest_boot(
                    qemu, qemu_nbd, args.kernel, args.initramfs,
                    alpine_socket, device, "alpine-delete",
                    b"VEYRA_SNAPCORE_BOOTED_ROOT_FULL_DELETE_PASS",
                    args.log, work, ALPINE_VOLUME_SIZE,
                )
                run_cli(alpine_store, "rollback", "alpine-openrc-root")
                run_cli(alpine_store, "verify")
                guest_boot(
                    qemu, qemu_nbd, args.kernel, args.initramfs,
                    alpine_socket, device, "alpine-verify",
                    b"VEYRA_SNAPCORE_ALPINE_RESTORE_PASS",
                    args.log, work, ALPINE_VOLUME_SIZE,
                )
                alpine_serial = args.log.read_bytes()
                required_markers = (
                    b"VEYRA_SNAPCORE_ALPINE_OPENRC_STARTED",
                    b"VEYRA_SNAPCORE_ALPINE_MUTATION_PASS",
                    b"VEYRA_SNAPCORE_ALPINE_E2FSCK_PASS",
                    b"VEYRA_SNAPCORE_ALPINE_RESTORE_PASS",
                )
                missing = [marker.decode() for marker in required_markers
                           if marker not in alpine_serial]
                if missing:
                    raise RuntimeError(
                        "Alpine/OpenRC serial proof is missing: " + ", ".join(missing)
                    )
                print("VEYRA_SNAPCORE_ALPINE_OPENRC_QEMU_PASS")
            finally:
                if alpine_server is not None:
                    alpine_server.terminate()
                    try:
                        alpine_server.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        alpine_server.kill()
                        alpine_server.wait(timeout=5)
                    if alpine_server.returncode not in (0, -15):
                        details = alpine_server_log.read_text(errors="replace")
                        raise RuntimeError(
                            f"Alpine nbdkit exited with status "
                            f"{alpine_server.returncode}:\n{details[-12000:]}"
                        )

            print(
                "NOTE: Alpine/OpenRC and the BusyBox fixture both boot through "
                "the file-backed SnapCore test adapter; this is not the installed "
                "Veyra user root or a production block-device proof."
            )
        finally:
            if server is not None:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
                if server.returncode not in (0, -15):
                    details = server_log_path.read_text(errors="replace")
                    raise RuntimeError(
                        f"nbdkit exited with status {server.returncode}:\n"
                        f"{details[-12000:]}"
                    )


if __name__ == "__main__":
    try:
        main()
    except (
        OSError, RuntimeError, TimeoutError, subprocess.SubprocessError,
        pexpect.ExceptionPexpect,
    ) as error:
        print(f"VEYRA_SNAPCORE_BOOTED_ROOT_QEMU_FAIL: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)
