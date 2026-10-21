"""Test-only NBD adapter for the experimental file-backed SnapCore engine.

This is a disposable QEMU test bridge. It does not select a production block
interface or provide a security boundary.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import nbdkit

REPOSITORY = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY))

from snapcore import SnapCoreVolume  # noqa: E402

API_VERSION = 2
_store_path: Path | None = None


@dataclass
class Handle:
    volume: SnapCoreVolume
    readonly: bool


def config(key: str, value: str) -> None:
    global _store_path
    if key != "store":
        raise RuntimeError(f"unsupported plugin option: {key}")
    if _store_path is not None:
        raise RuntimeError("store may be configured only once")
    _store_path = Path(value)


def config_complete() -> None:
    if _store_path is None:
        raise RuntimeError("required plugin option is missing: store")


def open(readonly: bool) -> Handle:
    assert _store_path is not None
    return Handle(SnapCoreVolume.open(_store_path), readonly)


def close(handle: Handle) -> None:
    handle.volume.close()


def export_description(handle: Handle) -> str:
    del handle
    return "Experimental Veyra SnapCore test volume; not production storage"


def get_size(handle: Handle) -> int:
    return handle.volume.size_bytes


def block_size(handle: Handle) -> tuple[int, int, int]:
    return (512, 4096, 1024 * 1024)


def can_write(handle: Handle) -> bool:
    return not handle.readonly


def can_multi_conn(handle: Handle) -> bool:
    # SnapCore holds one exclusive volume lock. The test export has one client.
    del handle
    return False


def can_flush(handle: Handle) -> bool:
    del handle
    return True


def can_fua(handle: Handle) -> int:
    # Every engine write fsyncs immutable extents, mapping metadata, and journal.
    del handle
    return nbdkit.FUA_NATIVE


def pread(handle: Handle, buffer: Any, offset: int, flags: int) -> None:
    del flags
    buffer[:] = handle.volume.read(offset, len(buffer))


def pwrite(handle: Handle, buffer: Any, offset: int, flags: int) -> None:
    del flags
    if handle.readonly:
        raise PermissionError("read-only SnapCore export")
    handle.volume.write(offset, buffer)


def flush(handle: Handle, flags: int) -> None:
    # Writes are durable before pwrite returns; no dirty cache is maintained.
    del handle, flags
