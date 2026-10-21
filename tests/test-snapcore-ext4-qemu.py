#!/usr/bin/env python3
"""Verify ext4 writes and SnapCore rollback across disposable QEMU boots."""

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
            raise RuntimeError(f"nbdkit exited during startup with status {server.returncode}")
        if socket.exists():
            return
        time.sleep(0.05)
    raise TimeoutError("nbdkit did not create its Unix socket")


def guest_boot(
    qemu: str,
    kernel: pathlib.Path,
    initramfs: pathlib.Path,
    block_device: pathlib.Path,
    phase: str,
    expected_marker: bytes,
    logfile,
) -> None:
    drive = f"file={block_device},if=virtio,format=raw,cache=writeback"
    command = [
        "-machine", "q35,accel=tcg", "-m", "768", "-smp", "2",
        "-nodefaults", "-nographic", "-no-reboot",
        "-serial", "stdio", "-monitor", "none",
        "-kernel", str(kernel.resolve()),
        "-initrd", str(initramfs.resolve()),
        "-drive", drive,
        "-append", f"console=ttyS0,115200 panic=1 veyra_snapcore_phase={phase}",
    ]
    guest = pexpect.spawn("sudo", ["-n", qemu, *command], encoding=None, timeout=240)
    guest.logfile_read = logfile
    try:
        outcome = guest.expect(
            [expected_marker, b"VEYRA_SNAPCORE_FAILURE:", b"Kernel panic"],
            timeout=240,
        )
        if outcome != 0:
            raise RuntimeError(
                f"QEMU phase {phase} failed before its success marker (serial match {outcome})"
            )
        guest.expect(pexpect.EOF, timeout=30)
        guest.close()
        if guest.exitstatus not in (0, None):
            raise RuntimeError(f"QEMU phase {phase} exited with status {guest.exitstatus}")
    finally:
        if guest.isalive():
            guest.close(force=True)


def connect_kernel_nbd(
    qemu_nbd: str,
    socket: pathlib.Path,
    device: pathlib.Path,
    expected_size: int,
    log_path: pathlib.Path,
) -> subprocess.Popen[bytes]:
    subprocess.run(["sudo", "-n", "modprobe", "nbd"], check=True, timeout=30)
    deadline = time.monotonic() + 15
    while not device.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    if not device.exists():
        raise RuntimeError(f"kernel NBD device was not created: {device}")
    current = subprocess.run(
        ["sudo", "-n", "blockdev", "--getsize64", str(device)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=5,
    )
    if not current.stdout.strip().isdigit() or int(current.stdout.strip()) != 0:
        raise RuntimeError(f"kernel NBD device is already attached: {device}")

    with log_path.open("wb") as device_log:
        server = subprocess.Popen(
            [
                "sudo", "-n", qemu_nbd, "--connect", str(device),
                "--format=raw", f"nbd:unix:{socket}",
            ],
            stdout=device_log,
            stderr=subprocess.STDOUT,
        )

    try:
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if server.poll() is not None:
                details = log_path.read_text(errors="replace")
                raise RuntimeError(
                    f"qemu-nbd exited during attachment with status {server.returncode}: "
                    f"{details[-4000:]}"
                )
            result = subprocess.run(
                ["sudo", "-n", "blockdev", "--getsize64", str(device)],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
            )
            if result.returncode == 0 and result.stdout.strip().isdigit():
                actual_size = int(result.stdout.strip())
                if actual_size == expected_size:
                    return server
                if actual_size != 0:
                    raise RuntimeError(
                        f"{device} has unexpected size {actual_size}, expected {expected_size}"
                    )
            time.sleep(0.05)
        raise TimeoutError(f"kernel NBD device {device} did not become ready")
    except Exception:
        if server.poll() is None:
            try:
                subprocess.run(
                    ["sudo", "-n", qemu_nbd, "--disconnect", str(device)],
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=15,
                )
            except (OSError, subprocess.SubprocessError):
                pass
            if server.poll() is None:
                server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=5)
        raise


def disconnect_kernel_nbd(
    qemu_nbd: str,
    device: pathlib.Path,
    server: subprocess.Popen[bytes],
) -> None:
    disconnect_error = None
    try:
        result = subprocess.run(
            ["sudo", "-n", qemu_nbd, "--disconnect", str(device)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=15,
        )
        if result.returncode != 0:
            disconnect_error = RuntimeError(
                f"could not disconnect kernel NBD device {device}: {result.stdout.strip()}"
            )
    except (OSError, subprocess.SubprocessError) as error:
        disconnect_error = error

    try:
        server.wait(timeout=15)
    except subprocess.TimeoutExpired:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=5)
    if disconnect_error is not None:
        raise RuntimeError(f"could not disconnect kernel NBD device {device}: {disconnect_error}")
    if server.returncode not in (0, -15):
        raise RuntimeError(f"qemu-nbd exited with status {server.returncode}")


def guest_boot_via_kernel_nbd(
    qemu: str,
    qemu_nbd: str,
    kernel: pathlib.Path,
    initramfs: pathlib.Path,
    socket: pathlib.Path,
    device: pathlib.Path,
    phase: str,
    expected_marker: bytes,
    logfile,
    nbd_log_path: pathlib.Path,
) -> None:
    server = connect_kernel_nbd(
        qemu_nbd, socket, device, VOLUME_SIZE, nbd_log_path
    )
    try:
        guest_boot(
            qemu, kernel, initramfs, device, phase, expected_marker, logfile
        )
    finally:
        disconnect_kernel_nbd(qemu_nbd, device, server)

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=pathlib.Path)
    parser.add_argument("initramfs", type=pathlib.Path)
    parser.add_argument("--log", type=pathlib.Path, default=pathlib.Path("snapcore-qemu.log"))
    args = parser.parse_args()
    qemu = shutil.which("qemu-system-x86_64")
    qemu_nbd = shutil.which("qemu-nbd")
    nbdkit = shutil.which("nbdkit")
    if (
        not qemu
        or not qemu_nbd
        or not nbdkit
        or not args.kernel.is_file()
        or not args.initramfs.is_file()
    ):
        parser.error("QEMU, qemu-nbd, nbdkit, kernel and initramfs are required")

    args.log.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="veyra-snapcore-qemu-") as temporary:
        work = pathlib.Path(temporary)
        store = work / "snapcore-volume"
        socket = work / "snapcore.sock"
        device = pathlib.Path("/dev/nbd0")
        server_log_path = work / "nbdkit.log"
        run_cli(store, "format", "--size-bytes", str(VOLUME_SIZE), "--block-size", "4096")
        with server_log_path.open("wb") as server_log:
            server = subprocess.Popen(
                [nbdkit, "-f", "-U", str(socket), "python", str(PLUGIN), f"store={store}"],
                stdout=server_log,
                stderr=subprocess.STDOUT,
            )
        try:
            wait_for_socket(server, socket)
            with args.log.open("wb") as serial_log:
                guest_boot_via_kernel_nbd(
                    qemu, qemu_nbd, args.kernel, args.initramfs, socket, device,
                    "baseline", b"VEYRA_SNAPCORE_BASELINE_PASS", serial_log,
                    work / "qemu-nbd-baseline.log",
                )
            run_cli(store, "snapshot", "clean-ext4")
            status = json.loads(run_cli(store, "status"))
            if "clean-ext4" not in [item["name"] for item in status["snapshots"]]:
                raise RuntimeError("SnapCore did not retain the clean ext4 checkpoint")

            with args.log.open("ab") as serial_log:
                guest_boot_via_kernel_nbd(
                    qemu, qemu_nbd, args.kernel, args.initramfs, socket, device,
                    "mutate", b"VEYRA_SNAPCORE_MUTATION_PASS", serial_log,
                    work / "qemu-nbd-mutate.log",
                )
            run_cli(store, "rollback", "clean-ext4")
            run_cli(store, "verify")

            with args.log.open("ab") as serial_log:
                guest_boot_via_kernel_nbd(
                    qemu, qemu_nbd, args.kernel, args.initramfs, socket, device,
                    "verify", b"VEYRA_SNAPCORE_ROLLBACK_EXT4_PASS", serial_log,
                    work / "qemu-nbd-verify.log",
                )
            print("VEYRA_SNAPCORE_QEMU_EXT4_ROLLBACK_PASS")
            print("NOTE: ext4 uses the host kernel NBD device; SnapCore storage remains file-backed.")
        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
            if server.returncode not in (0, -15):
                details = server_log_path.read_text(errors="replace")
                raise RuntimeError(
                    f"nbdkit exited with status {server.returncode}:\\n{details[-12000:]}"
                )


if __name__ == "__main__":
    try:
        main()
    except (
        OSError, RuntimeError, TimeoutError, subprocess.SubprocessError,
        pexpect.ExceptionPexpect,
    ) as error:
        print(f"VEYRA_SNAPCORE_QEMU_FAIL: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)
