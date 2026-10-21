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
    home_device: pathlib.Path | None = None,
) -> None:
    drives = [
        "-drive",
        f"file={block_device.resolve()},if=virtio,format=raw,cache=writeback",
    ]
    if home_device is not None:
        drives.extend([
            "-drive",
            f"file={home_device.resolve()},if=virtio,format=raw,cache=writeback",
        ])
    command = [
        "-machine", "q35,accel=tcg", "-m", "768", "-smp", "2",
        "-nodefaults", "-nographic", "-no-reboot",
        "-serial", "stdio", "-monitor", "none",
        "-kernel", str(kernel.resolve()),
        "-initrd", str(initramfs.resolve()),
        *drives,
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
    expected_size: int,
    log_path: pathlib.Path,
) -> None:
    subprocess.run(["sudo", "-n", "modprobe", "nbd"], check=True, timeout=30)
    deadline = time.monotonic() + 15
    while not device.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    if not device.exists():
        raise RuntimeError(f"kernel NBD device was not created: {device}")
    current_size = kernel_nbd_size(device)
    if current_size is None:
        raise RuntimeError(f"could not inspect kernel NBD device: {device}")
    if current_size != 0:
        raise RuntimeError(f"kernel NBD device is already attached: {device}")

    connect_attempted = False
    try:
        # qemu-nbd daemonizes in --connect mode; its parent exiting is expected.
        connect_attempted = True
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
            f"kernel NBD device {device} did not become ready; qemu-nbd log: "
            f"{details[-4000:]}"
        )
    except Exception:
        if connect_attempted:
            try:
                disconnect_kernel_nbd(qemu_nbd, device)
            except (OSError, RuntimeError, TimeoutError, subprocess.SubprocessError):
                pass
        raise


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
    home_socket: pathlib.Path | None = None,
    home_device: pathlib.Path | None = None,
    home_nbd_log_path: pathlib.Path | None = None,
) -> None:
    has_home = home_socket is not None or home_device is not None or home_nbd_log_path is not None
    if has_home and not all((home_socket, home_device, home_nbd_log_path)):
        raise ValueError("home NBD socket, device, and log path must be supplied together")

    connect_kernel_nbd(qemu_nbd, socket, device, VOLUME_SIZE, nbd_log_path)
    home_connected = False
    try:
        if has_home:
            assert home_socket is not None
            assert home_device is not None
            assert home_nbd_log_path is not None
            connect_kernel_nbd(
                qemu_nbd, home_socket, home_device, VOLUME_SIZE, home_nbd_log_path
            )
            home_connected = True
        guest_boot(
            qemu, kernel, initramfs, device, phase, expected_marker, logfile,
            home_device=home_device if has_home else None,
        )
    finally:
        try:
            if home_connected:
                assert home_device is not None
                disconnect_kernel_nbd(qemu_nbd, home_device)
        finally:
            disconnect_kernel_nbd(qemu_nbd, device)

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
        root_store = work / "snapcore-user-root"
        home_store = work / "snapcore-home"
        root_socket = work / "snapcore-root.sock"
        home_socket = work / "snapcore-home.sock"
        root_device = pathlib.Path("/dev/nbd0")
        home_device = pathlib.Path("/dev/nbd1")
        server_specs = [
            (root_store, root_socket, work / "nbdkit-root.log"),
            (home_store, home_socket, work / "nbdkit-home.log"),
        ]
        server_processes: list[subprocess.Popen[bytes]] = []

        run_cli(root_store, "format", "--size-bytes", str(VOLUME_SIZE), "--block-size", "4096")
        run_cli(home_store, "format", "--size-bytes", str(VOLUME_SIZE), "--block-size", "4096")

        def boot(
            phase: str,
            marker: bytes,
            serial_mode: str,
        ) -> None:
            with args.log.open(serial_mode) as serial_log:
                guest_boot_via_kernel_nbd(
                    qemu, qemu_nbd, args.kernel, args.initramfs,
                    root_socket, root_device, phase, marker, serial_log,
                    work / f"qemu-nbd-root-{phase}.log",
                    home_socket=home_socket,
                    home_device=home_device,
                    home_nbd_log_path=work / f"qemu-nbd-home-{phase}.log",
                )

        try:
            for store, socket, server_log_path in server_specs:
                with server_log_path.open("wb") as server_log:
                    server = subprocess.Popen(
                        [
                            nbdkit, "-f", "-U", str(socket),
                            "python", str(PLUGIN), f"store={store}",
                        ],
                        stdout=server_log,
                        stderr=subprocess.STDOUT,
                    )
                server_processes.append(server)
                wait_for_socket(server, socket)

            boot(
                "baseline",
                b"VEYRA_SNAPCORE_TWO_VOLUME_BASELINE_PASS",
                "wb",
            )
            run_cli(root_store, "snapshot", "clean-user-root")
            run_cli(home_store, "snapshot", "clean-home")
            root_status = json.loads(run_cli(root_store, "status"))
            home_status = json.loads(run_cli(home_store, "status"))
            if "clean-user-root" not in [item["name"] for item in root_status["snapshots"]]:
                raise RuntimeError("SnapCore did not retain the user-root checkpoint")
            if "clean-home" not in [item["name"] for item in home_status["snapshots"]]:
                raise RuntimeError("SnapCore did not retain the separate /home checkpoint")

            boot(
                "mutate",
                b"VEYRA_SNAPCORE_TWO_VOLUME_MUTATION_PASS",
                "ab",
            )
            run_cli(root_store, "rollback", "clean-user-root")
            run_cli(root_store, "verify")

            boot(
                "verify-root",
                b"VEYRA_SNAPCORE_ROOT_ONLY_RESTORE_HOME_PRESERVED_PASS",
                "ab",
            )
            boot(
                "destroy-root",
                b"VEYRA_SNAPCORE_FULL_USER_ROOT_DELETE_PASS",
                "ab",
            )
            run_cli(root_store, "verify")
            run_cli(root_store, "rollback", "clean-user-root")
            run_cli(root_store, "verify")

            boot(
                "verify-root-after-delete",
                b"VEYRA_SNAPCORE_FULL_ROOT_RESTORE_HOME_PRESERVED_PASS",
                "ab",
            )
            run_cli(home_store, "rollback", "clean-home")
            run_cli(home_store, "verify")

            boot(
                "verify-home",
                b"VEYRA_SNAPCORE_SEPARATE_HOME_RESTORE_PASS",
                "ab",
            )
            print("VEYRA_SNAPCORE_QEMU_EXT4_FULL_ROOT_HOME_RESTORE_PASS")
            print(
                "NOTE: full user-root deletion and separate /home restoration were "
                "tested using file-backed SnapCore volumes exported through host kernel NBD."
            )
        finally:
            active_error = sys.exc_info()[0] is not None
            for server in server_processes:
                server.terminate()
            for server, (_, _, server_log_path) in zip(server_processes, server_specs):
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
                if server.returncode not in (0, -15):
                    details = server_log_path.read_text(errors="replace")
                    message = (
                        f"nbdkit exited with status {server.returncode}:\n"
                        f"{details[-12000:]}"
                    )
                    if active_error:
                        print(message, file=sys.stderr, flush=True)
                    else:
                        raise RuntimeError(message)


if __name__ == "__main__":
    try:
        main()
    except (
        OSError, RuntimeError, TimeoutError, subprocess.SubprocessError,
        pexpect.ExceptionPexpect,
    ) as error:
        print(f"VEYRA_SNAPCORE_QEMU_FAIL: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)
