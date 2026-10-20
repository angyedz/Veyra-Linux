"""Experimental file-backed block CoW volume for SnapCore.

This prototype is deliberately not wired into the boot path. Immutable extent
files and immutable logical maps are committed by an fsync-backed append-only
journal. It provides integrity checks and replay, but it is not a production
block device, a filesystem-consistent snapshot service, or a security boundary.
"""

from __future__ import annotations

import fcntl
from functools import wraps
import hashlib
import json
import os
import re
import stat
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Iterable, Optional

FORMAT_VERSION = 2
_MAGIC = "VEYRA-SNAPCORE"
_MAX_BLOCK_SIZE = 1024 * 1024
_MAX_RECORD_SIZE = 1024 * 1024
_MAX_COMPACT_GENERATIONS = 8192
_MAX_COMPACT_SNAPSHOTS = 4096
_HEX = re.compile(r"^[0-9a-f]{64}$")
_SNAPSHOT_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
_FAULT_HOOK = Optional[Callable[[str], None]]


def _synchronized(method: Callable[..., Any]) -> Callable[..., Any]:
    """Serialize operations sharing one open volume handle across threads."""
    @wraps(method)
    def wrapper(self: "SnapCoreVolume", *args: Any, **kwargs: Any) -> Any:
        with self._thread_lock:
            return method(self, *args, **kwargs)

    return wrapper


class SnapCoreError(Exception):
    """Base error for invalid operations and unsupported prototype state."""


class IntegrityError(SnapCoreError):
    """Raised when durable metadata or an extent fails integrity checks."""


def _canonical(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("ascii")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _object_pairs_no_duplicates(pairs: Iterable[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _decode_json(data: bytes, label: str) -> Any:
    try:
        return json.loads(
            data.decode("ascii"), object_pairs_hook=_object_pairs_no_duplicates
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise IntegrityError(f"invalid {label}: {exc}") from exc


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        count = os.write(fd, view)
        if count <= 0:
            raise OSError("short write")
        view = view[count:]


def _fsync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | _NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _read_regular(path: Path, max_bytes: int) -> bytes:
    try:
        fd = os.open(path, os.O_RDONLY | _NOFOLLOW)
    except OSError as exc:
        raise IntegrityError(f"cannot safely open {path.name}: {exc}") from exc
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise IntegrityError(f"{path.name} is not a regular file")
        if info.st_size > max_bytes:
            raise IntegrityError(f"{path.name} exceeds the prototype size limit")
        chunks = []
        remaining = max_bytes + 1
        while remaining:
            chunk = os.read(fd, min(remaining, 65536))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > max_bytes:
            raise IntegrityError(f"{path.name} exceeds the prototype size limit")
        return data
    finally:
        os.close(fd)


def _write_immutable(
    path: Path,
    data: bytes,
    parent: Path,
    *,
    fault_hook: _FAULT_HOOK = None,
    fault_point: Optional[str] = None,
) -> bool:
    """Create and durably publish immutable bytes; return whether newly written."""
    temporary = parent / f".pending-{uuid.uuid4().hex}"
    fd = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | _NOFOLLOW,
        0o600,
    )
    try:
        _write_all(fd, data)
        if fault_hook is not None and fault_point is not None:
            fault_hook(f"{fault_point}_temp")
        os.fsync(fd)
    except BaseException:
        os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    else:
        os.close(fd)

    created = False
    try:
        try:
            os.link(temporary, path, follow_symlinks=False)
            created = True
        except FileExistsError:
            if _read_regular(path, max(len(data), 1)) != data:
                raise IntegrityError(f"immutable object collision at {path.name}")
    finally:
        os.unlink(temporary)
    if created:
        _fsync_directory(parent)
    return created


def _checked_directory(path: Path, label: str) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        raise IntegrityError(f"missing {label} directory: {exc}") from exc
    if not stat.S_ISDIR(info.st_mode):
        raise IntegrityError(f"{label} is not a real directory")
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise IntegrityError(f"{label} directory must not be accessible to group/other")


class SnapCoreVolume:
    """An experimental logical block volume with immutable CoW generations.

    The internal fault hook terminates child processes at named persistence
    boundaries so tests can replay state after SIGKILL-like failures. It is not
    a runtime control surface.
    """

    def __init__(self, root: Path, lock_fd: int, fault_hook: _FAULT_HOOK = None):
        self.root = root
        self._lock_fd = lock_fd
        self._fault_hook = fault_hook
        self._thread_lock = threading.RLock()
        self._closed = False
        self._poisoned = False
        self._state: dict[str, Any] = {}

    @classmethod
    def format(
        cls,
        path: os.PathLike[str] | str,
        size_bytes: int,
        block_size: int = 4096,
    ) -> "SnapCoreVolume":
        """Create a new empty volume and return it open under an exclusive lock."""
        root = Path(path)
        if isinstance(size_bytes, bool) or not isinstance(size_bytes, int):
            raise ValueError("size_bytes must be an integer")
        if size_bytes <= 0 or size_bytes > (1 << 63) - 1:
            raise ValueError("size_bytes must be positive and fit in signed 64 bits")
        if isinstance(block_size, bool) or not isinstance(block_size, int):
            raise ValueError("block_size must be an integer")
        if (
            block_size < 16
            or block_size > _MAX_BLOCK_SIZE
            or block_size & (block_size - 1)
        ):
            raise ValueError("block_size must be a power of two from 16 to 1048576")
        if size_bytes % block_size:
            raise ValueError("size_bytes must be a multiple of block_size")
        if root.exists() or root.is_symlink():
            info = root.lstat()
            if not stat.S_ISDIR(info.st_mode) or any(root.iterdir()):
                raise SnapCoreError("refusing to format a non-empty or non-directory path")
            os.chmod(root, 0o700)
        else:
            root.mkdir(parents=True, mode=0o700)
        _checked_directory(root, "volume")
        (root / "extents").mkdir(mode=0o700)
        (root / "roots").mkdir(mode=0o700)
        _fsync_directory(root)

        body = {
            "magic": _MAGIC,
            "format_version": FORMAT_VERSION,
            "volume_id": str(uuid.uuid4()),
            "size_bytes": size_bytes,
            "block_size": block_size,
        }
        envelope = {"body": body, "checksum": _sha256(_canonical(body))}
        _write_immutable(root / "format.json", _canonical(envelope) + b"\n", root)
        journal_fd = os.open(
            root / "journal.log",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | _NOFOLLOW,
            0o600,
        )
        try:
            os.fsync(journal_fd)
        finally:
            os.close(journal_fd)
        _fsync_directory(root)

        empty_root = cls._root_document({})
        root_id = cls._root_id(empty_root)
        _write_immutable(
            root / "roots" / f"{root_id}.json",
            _canonical(empty_root) + b"\n",
            root / "roots",
        )
        lock_fd = os.open(
            root / ".lock", os.O_RDWR | os.O_CREAT | _NOFOLLOW, 0o600
        )
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            volume = cls(root, lock_fd)
            volume._load_format()
            volume._append_event(
                operation="init",
                generation_id=1,
                parent_generation=None,
                root_id=root_id,
            )
            return volume
        except BaseException:
            os.close(lock_fd)
            raise

    @classmethod
    def open(
        cls,
        path: os.PathLike[str] | str,
        *,
        _fault_hook: _FAULT_HOOK = None,
    ) -> "SnapCoreVolume":
        root = Path(path)
        _checked_directory(root, "volume")
        lock_path = root / ".lock"
        lock_fd = os.open(
            lock_path,
            os.O_RDWR | os.O_CREAT | _NOFOLLOW,
            0o600,
        )
        try:
            if not stat.S_ISREG(os.fstat(lock_fd).st_mode):
                raise IntegrityError("volume lock is not a regular file")
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            volume = cls(root, lock_fd, _fault_hook)
            volume._load_format()
            _checked_directory(root / "extents", "extent store")
            _checked_directory(root / "roots", "mapping root store")
            volume._replay_journal()
            volume._cleanup_journal_temps()
            return volume
        except BaseException:
            os.close(lock_fd)
            raise

    @_synchronized
    def close(self) -> None:
        if not self._closed:
            self._closed = True
            try:
                fcntl.flock(self._lock_fd, fcntl.LOCK_UN)
            finally:
                os.close(self._lock_fd)

    @_synchronized
    def __enter__(self) -> "SnapCoreVolume":
        self._ensure_open()
        return self

    @_synchronized
    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        self.close()

    @property
    @_synchronized
    def size_bytes(self) -> int:
        self._ensure_open()
        return self._state["format"]["size_bytes"]

    @property
    @_synchronized
    def block_size(self) -> int:
        self._ensure_open()
        return self._state["format"]["block_size"]

    @property
    @_synchronized
    def head_generation(self) -> int:
        self._ensure_open()
        return self._state["head_generation"]

    @property
    @_synchronized
    def volume_id(self) -> str:
        self._ensure_open()
        return self._state["format"]["volume_id"]

    @_synchronized
    def generations(self) -> list[dict[str, Any]]:
        self._ensure_open()
        return [dict(item) for item in self._state["generations"]]

    @_synchronized
    def snapshots(self, *, verify: bool = False) -> list[dict[str, Any]]:
        self._ensure_open()
        result = [
            {"name": name, **dict(snapshot)}
            for name, snapshot in sorted(self._state["snapshots"].items())
        ]
        if verify:
            for snapshot in result:
                generation = self._generation(snapshot["generation_id"])
                self._verify_root(generation["root_id"], verify_extents=True)
        return result

    @_synchronized
    def snapshot(self, name: str) -> dict[str, Any]:
        self._ensure_open()
        self._validate_snapshot_name(name)
        if name in self._state["snapshots"]:
            raise SnapCoreError(f"snapshot already exists: {name}")
        generation_id = self.head_generation
        root_id = self._generation(generation_id)["root_id"]
        # A checkpoint must not turn already-corrupt data into a seemingly
        # recoverable point. Validate every referenced block before publishing
        # the durable snapshot event.
        self._verify_root(root_id, verify_extents=True)
        self._append_event(
            operation="snapshot",
            generation_id=generation_id,
            parent_generation=None,
            root_id=root_id,
            snapshot_name=name,
            snapshot_generation=generation_id,
        )
        return dict(self._state["snapshots"][name])

    @_synchronized
    def write(self, offset: int, data: bytes | bytearray | memoryview) -> int:
        """Write bytes into a new immutable map generation using block CoW."""
        self._ensure_open()
        if isinstance(offset, bool) or not isinstance(offset, int) or offset < 0:
            raise ValueError("offset must be a non-negative integer")
        payload = bytes(data)
        if offset + len(payload) > self.size_bytes:
            raise ValueError("write extends past the logical volume")
        if not payload:
            return self.head_generation

        current = self._generation(self.head_generation)
        blocks = self._load_root(current["root_id"])
        bs = self.block_size
        first = offset // bs
        last = (offset + len(payload) - 1) // bs
        for block_index in range(first, last + 1):
            block_start = block_index * bs
            write_start = max(offset, block_start)
            write_end = min(offset + len(payload), block_start + bs)
            if write_start == block_start and write_end == block_start + bs:
                block = bytearray(bs)
            elif str(block_index) in blocks:
                block = bytearray(self._read_extent(blocks[str(block_index)]))
            else:
                block = bytearray(bs)
            src_start = write_start - offset
            dst_start = write_start - block_start
            block[dst_start : dst_start + (write_end - write_start)] = payload[
                src_start : src_start + (write_end - write_start)
            ]
            if not any(block):
                blocks.pop(str(block_index), None)
            else:
                blocks[str(block_index)] = self._store_extent(bytes(block))

        root_document = self._root_document(blocks)
        root_id = self._root_id(root_document)
        self._store_root(root_id, root_document)
        new_generation = self.head_generation + 1
        self._append_event(
            operation="write",
            generation_id=new_generation,
            parent_generation=self.head_generation,
            root_id=root_id,
        )
        return new_generation

    @_synchronized
    def read(self, offset: int, length: int) -> bytes:
        """Read logical bytes, returning zeroes for unmapped sparse blocks."""
        self._ensure_open()
        if (
            isinstance(offset, bool)
            or not isinstance(offset, int)
            or offset < 0
            or isinstance(length, bool)
            or not isinstance(length, int)
            or length < 0
        ):
            raise ValueError("offset and length must be non-negative integers")
        if offset + length > self.size_bytes:
            raise ValueError("read extends past the logical volume")
        if length == 0:
            return b""
        blocks = self._load_root(self._generation(self.head_generation)["root_id"])
        bs = self.block_size
        output = bytearray(length)
        first = offset // bs
        last = (offset + length - 1) // bs
        for block_index in range(first, last + 1):
            raw = (
                self._read_extent(blocks[str(block_index)])
                if str(block_index) in blocks
                else bytes(bs)
            )
            src_start = max(offset, block_index * bs) - block_index * bs
            src_end = min(offset + length, (block_index + 1) * bs) - block_index * bs
            dst_start = max(offset, block_index * bs) - offset
            output[dst_start : dst_start + (src_end - src_start)] = raw[
                src_start:src_end
            ]
        return bytes(output)

    @_synchronized
    def rollback(self, name: str) -> int:
        """Create a new writable head based on a retained immutable snapshot."""
        self._ensure_open()
        self._validate_snapshot_name(name)
        try:
            snapshot = self._state["snapshots"][name]
        except KeyError as exc:
            raise SnapCoreError(f"unknown snapshot: {name}") from exc
        # Do not commit a new head that points at missing or damaged snapshot
        # data. The journal append is the restore commit boundary.
        self._verify_root(snapshot["root_id"], verify_extents=True)
        generation_id = self.head_generation + 1
        self._append_event(
            operation="rollback",
            generation_id=generation_id,
            parent_generation=self.head_generation,
            root_id=snapshot["root_id"],
            target_snapshot=name,
            snapshot_generation=snapshot["generation_id"],
        )
        return generation_id

    @_synchronized
    def delete_snapshot(self, name: str) -> None:
        """Remove a checkpoint name without pruning its immutable generation."""
        self._ensure_open()
        self._validate_snapshot_name(name)
        try:
            snapshot = self._state["snapshots"][name]
        except KeyError as exc:
            raise SnapCoreError(f"unknown snapshot: {name}") from exc
        remaining = [
            item for other_name, item in self._state["snapshots"].items()
            if other_name != name
        ]
        if not remaining:
            raise SnapCoreError("refusing to delete the last named recovery checkpoint")
        for item in remaining:
            self._verify_root(item["root_id"], verify_extents=True)
        head = self._generation(self.head_generation)
        self._append_event(
            operation="delete_snapshot",
            generation_id=self.head_generation,
            parent_generation=None,
            root_id=head["root_id"],
            snapshot_name=name,
            snapshot_generation=snapshot["generation_id"],
        )

    @_synchronized
    def prune_generations(self, keep_last: int) -> dict[str, Any]:
        """Compact history while retaining the head and every named checkpoint."""
        self._ensure_open()
        if (
            isinstance(keep_last, bool)
            or not isinstance(keep_last, int)
            or keep_last < 1
            or keep_last > _MAX_COMPACT_GENERATIONS
        ):
            raise ValueError(
                f"keep_last must be an integer from 1 to {_MAX_COMPACT_GENERATIONS}"
            )
        if not self._state["snapshots"]:
            raise SnapCoreError("refusing to prune without a named recovery checkpoint")

        # Validate the complete source state before making any history unreachable.
        self.verify()
        verified_snapshots = self.snapshots(verify=True)
        retained_ids = {
            item["generation_id"] for item in self._state["generations"][-keep_last:]
        }
        retained_ids.add(self.head_generation)
        retained_ids.update(item["generation_id"] for item in verified_snapshots)
        retained = [
            dict(item)
            for item in self._state["generations"]
            if item["generation_id"] in retained_ids
        ]
        for item in retained:
            if item["parent_generation"] not in retained_ids:
                item["parent_generation"] = None
        removed = len(self._state["generations"]) - len(retained)
        if removed == 0:
            return {
                "removed_generations": 0,
                "retained_generations": len(retained),
                "head_generation": self.head_generation,
                "snapshots": [item["name"] for item in verified_snapshots],
                "compacted": False,
            }
        if len(retained) > _MAX_COMPACT_GENERATIONS:
            raise SnapCoreError("retained history exceeds the compacted journal limit")

        body = {
            "sequence": self._state["sequence"] + 1,
            "operation": "compact",
            "volume_id": self.volume_id,
            "previous_checksum": self._state["last_checksum"],
            "timestamp_ns": time.time_ns(),
            "generation_id": self.head_generation,
            "parent_generation": None,
            "root_id": self._generation(self.head_generation)["root_id"],
            "snapshot_name": None,
            "target_snapshot": None,
            "snapshot_generation": None,
            "base_state": {
                "generations": retained,
                "snapshots": {
                    item["name"]: {
                        "generation_id": item["generation_id"],
                        "root_id": item["root_id"],
                        "created_ns": item["created_ns"],
                    }
                    for item in verified_snapshots
                },
            },
        }
        record = {"body": body, "checksum": _sha256(_canonical(body))}
        encoded = _canonical(record) + b"\n"
        if len(encoded) > _MAX_RECORD_SIZE:
            raise SnapCoreError("compacted journal record exceeds prototype size limit")
        self._replace_journal(encoded, record)
        return {
            "removed_generations": removed,
            "retained_generations": len(self._state["generations"]),
            "head_generation": self.head_generation,
            "snapshots": sorted(self._state["snapshots"]),
            "compacted": True,
        }

    @_synchronized
    def collect_garbage(self) -> dict[str, int]:
        """Remove only unreferenced immutable objects and abandoned temp files.

        Every journaled generation is retained by this prototype, even after a
        named snapshot is deleted. Collection verifies all live roots and
        extents before unlinking anything, then removes only objects outside
        that complete reachability set. The volume lock serializes collection
        against writers and other collectors.
        """
        self._ensure_open()
        _checked_directory(self.root / "roots", "mapping root store")
        _checked_directory(self.root / "extents", "extent store")
        live_roots: set[str] = set()
        live_extents: set[str] = set()
        for generation in self._state["generations"]:
            root_id = generation["root_id"]
            blocks = self._verify_root(root_id, verify_extents=True)
            live_roots.add(root_id)
            live_extents.update(blocks.values())
        for snapshot in self._state["snapshots"].values():
            root_id = snapshot["root_id"]
            if root_id not in live_roots:
                blocks = self._verify_root(root_id, verify_extents=True)
                live_roots.add(root_id)
                live_extents.update(blocks.values())

        root_removals = self._garbage_candidates(
            self.root / "roots", suffix=".json", live_ids=live_roots
        )
        extent_removals = self._garbage_candidates(
            self.root / "extents", suffix=".blk", live_ids=live_extents
        )
        removed_roots = self._unlink_garbage(root_removals, "root")
        removed_extents = self._unlink_garbage(extent_removals, "extent")
        return {
            "removed_roots": removed_roots[0],
            "removed_root_temps": removed_roots[1],
            "removed_extents": removed_extents[0],
            "removed_extent_temps": removed_extents[1],
        }

    @staticmethod
    def _garbage_candidates(
        directory: Path, *, suffix: str, live_ids: set[str]
    ) -> list[tuple[Path, str]]:
        candidates: list[tuple[Path, str]] = []
        for path in directory.iterdir():
            name = path.name
            try:
                mode = path.lstat().st_mode
            except OSError as exc:
                raise IntegrityError(f"cannot inspect object in {directory.name}: {exc}") from exc
            if not stat.S_ISREG(mode):
                raise IntegrityError(f"unexpected non-regular object in {directory.name}")
            if re.fullmatch(r"\.pending-[0-9a-f]{32}", name):
                candidates.append((path, "temp"))
                continue
            if not name.endswith(suffix):
                raise IntegrityError(f"unexpected object name in {directory.name}: {name}")
            object_id = name[: -len(suffix)]
            if not _HEX.fullmatch(object_id):
                raise IntegrityError(f"invalid object name in {directory.name}: {name}")
            if object_id not in live_ids:
                candidates.append((path, "object"))
        return candidates

    def _unlink_garbage(self, candidates: list[tuple[Path, str]], kind: str) -> tuple[int, int]:
        removed_objects = 0
        removed_temps = 0
        if not candidates:
            return removed_objects, removed_temps
        for path, category in candidates:
            os.unlink(path)
            if category == "temp":
                removed_temps += 1
            else:
                removed_objects += 1
            self._fault(f"gc_{kind}_unlink")
        _fsync_directory(candidates[0][0].parent)
        return removed_objects, removed_temps

    @_synchronized
    def verify(self) -> dict[str, Any]:
        """Verify every retained generation, snapshot root, and referenced extent."""
        self._ensure_open()
        roots = {item["root_id"] for item in self._state["generations"]}
        for root_id in roots:
            self._verify_root(root_id, verify_extents=True)
        return {
            "volume_id": self.volume_id,
            "format_version": FORMAT_VERSION,
            "generations": len(self._state["generations"]),
            "snapshots": len(self._state["snapshots"]),
            "head_generation": self.head_generation,
            "verified_roots": len(roots),
        }

    def _ensure_open(self) -> None:
        if self._closed:
            raise SnapCoreError("volume is closed")
        if self._poisoned:
            raise SnapCoreError(
                "volume state is uncertain after a journal I/O failure; close and reopen it"
            )

    @staticmethod
    def _validate_snapshot_name(name: str) -> None:
        if (
            not isinstance(name, str)
            or name in {".", ".."}
            or not _SNAPSHOT_NAME.fullmatch(name)
        ):
            raise ValueError("snapshot name must use 1-128 safe ASCII letters, digits, ._-")

    @staticmethod
    def _root_document(blocks: dict[str, str]) -> dict[str, Any]:
        return {"format_version": FORMAT_VERSION, "blocks": dict(sorted(blocks.items()))}

    @staticmethod
    def _root_id(document: dict[str, Any]) -> str:
        return _sha256(_canonical(document))

    def _load_format(self) -> None:
        envelope = _decode_json(
            _read_regular(self.root / "format.json", 64 * 1024), "format metadata"
        )
        if not isinstance(envelope, dict) or set(envelope) != {"body", "checksum"}:
            raise IntegrityError("invalid format metadata envelope")
        body = envelope["body"]
        if (
            not isinstance(body, dict)
            or set(body)
            != {"magic", "format_version", "volume_id", "size_bytes", "block_size"}
            or envelope["checksum"] != _sha256(_canonical(body))
        ):
            raise IntegrityError("format metadata checksum mismatch")
        if (
            body.get("magic") != _MAGIC
            or body.get("format_version") != FORMAT_VERSION
            or not isinstance(body.get("volume_id"), str)
            or not body["volume_id"]
        ):
            raise SnapCoreError("unsupported SnapCore format or invalid volume identity")
        size_bytes = body.get("size_bytes")
        block_size = body.get("block_size")
        if (
            not isinstance(size_bytes, int)
            or isinstance(size_bytes, bool)
            or size_bytes <= 0
            or not isinstance(block_size, int)
            or isinstance(block_size, bool)
            or block_size < 16
            or block_size > _MAX_BLOCK_SIZE
            or block_size & (block_size - 1)
            or size_bytes % block_size
        ):
            raise IntegrityError("invalid logical volume geometry")
        self._state = {
            "format": body,
            "generations": [],
            "generation_by_id": {},
            "snapshots": {},
            "head_generation": 0,
            "sequence": 0,
            "last_checksum": "",
        }

    def _replay_journal(self) -> None:
        journal_path = self.root / "journal.log"
        journal = _read_regular(journal_path, 128 * 1024 * 1024)
        complete_end = journal.rfind(b"\n") + 1
        if complete_end != len(journal):
            fd = os.open(journal_path, os.O_WRONLY | _NOFOLLOW)
            try:
                os.ftruncate(fd, complete_end)
                os.fsync(fd)
            finally:
                os.close(fd)
        lines = journal[:complete_end].splitlines()
        if not lines:
            raise IntegrityError("journal has no committed initialization record")
        for line_number, line in enumerate(lines, start=1):
            if not line or len(line) > _MAX_RECORD_SIZE:
                raise IntegrityError(f"invalid journal record at line {line_number}")
            record = _decode_json(line, f"journal record {line_number}")
            self._apply_record(record, line_number)

    def _cleanup_journal_temps(self) -> None:
        removed = False
        for path in self.root.iterdir():
            if not re.fullmatch(r"\.journal\.pending-[0-9a-f]{32}", path.name):
                continue
            try:
                mode = path.lstat().st_mode
            except OSError as exc:
                raise IntegrityError(f"cannot inspect journal temporary: {exc}") from exc
            if not stat.S_ISREG(mode):
                raise IntegrityError("journal temporary is not a regular file")
            os.unlink(path)
            removed = True
        if removed:
            _fsync_directory(self.root)

    def _apply_record(self, record: Any, line_number: int) -> None:
        if not isinstance(record, dict) or set(record) != {"body", "checksum"}:
            raise IntegrityError(f"invalid journal envelope at line {line_number}")
        body = record["body"]
        checksum = record["checksum"]
        if not isinstance(body, dict) or checksum != _sha256(_canonical(body)):
            raise IntegrityError(f"journal checksum mismatch at line {line_number}")
        required = {
            "sequence",
            "operation",
            "volume_id",
            "previous_checksum",
            "timestamp_ns",
            "generation_id",
            "parent_generation",
            "root_id",
            "snapshot_name",
            "target_snapshot",
            "snapshot_generation",
        }
        is_compaction_anchor = (
            body.get("operation") == "compact"
            and self._state["sequence"] == 0
            and line_number == 1
        )
        expected_fields = required | ({"base_state"} if is_compaction_anchor else set())
        if set(body) != expected_fields:
            raise IntegrityError(f"invalid journal fields at line {line_number}")
        expected_sequence = self._state["sequence"] + 1
        if (
            not isinstance(body["sequence"], int)
            or isinstance(body["sequence"], bool)
            or body["sequence"] < 1
            or (not is_compaction_anchor and body["sequence"] != expected_sequence)
        ):
            raise IntegrityError(f"journal sequence mismatch at line {line_number}")
        if (
            not isinstance(body["timestamp_ns"], int)
            or isinstance(body["timestamp_ns"], bool)
            or body["timestamp_ns"] < 0
        ):
            raise IntegrityError(f"invalid journal timestamp at line {line_number}")
        if is_compaction_anchor:
            if (
                body["sequence"] < 2
                or not isinstance(body["previous_checksum"], str)
                or not _HEX.fullmatch(body["previous_checksum"])
            ):
                raise IntegrityError(f"invalid compacted journal anchor at line {line_number}")
        elif body["previous_checksum"] != self._state["last_checksum"]:
            raise IntegrityError(f"journal chain mismatch at line {line_number}")
        if body["volume_id"] != self.volume_id:
            raise IntegrityError(f"journal volume mismatch at line {line_number}")
        if not isinstance(body["root_id"], str) or not _HEX.fullmatch(body["root_id"]):
            raise IntegrityError(f"invalid mapping root id at line {line_number}")
        root = self._load_root(body["root_id"])
        generation_id = body["generation_id"]
        parent = body["parent_generation"]
        operation = body["operation"]
        if (
            not isinstance(generation_id, int)
            or isinstance(generation_id, bool)
            or generation_id < 1
        ):
            raise IntegrityError(f"invalid generation id at line {line_number}")
        if is_compaction_anchor:
            if (
                parent is not None
                or body["snapshot_name"] is not None
                or body["target_snapshot"] is not None
                or body["snapshot_generation"] is not None
            ):
                raise IntegrityError(f"invalid compacted journal anchor at line {line_number}")
            self._apply_compacted_base(body, checksum, line_number)
            return
        if operation == "init":
            if (
                expected_sequence != 1
                or generation_id != 1
                or parent is not None
                or body["snapshot_name"] is not None
                or body["target_snapshot"] is not None
                or body["snapshot_generation"] is not None
                or root
            ):
                raise IntegrityError("invalid initialization record")
            generation = self._generation_entry(1, None, body["root_id"], "init", body)
            self._state["generations"].append(generation)
            self._state["generation_by_id"][1] = generation
            self._state["head_generation"] = 1
        elif operation == "write":
            self._require_new_generation(generation_id, parent, line_number)
            if any(
                body[key] is not None
                for key in ("snapshot_name", "target_snapshot", "snapshot_generation")
            ):
                raise IntegrityError(f"invalid write metadata at line {line_number}")
            generation = self._generation_entry(
                generation_id, parent, body["root_id"], "write", body
            )
            self._state["generations"].append(generation)
            self._state["generation_by_id"][generation_id] = generation
            self._state["head_generation"] = generation_id
        elif operation == "snapshot":
            if (
                generation_id != self.head_generation
                or parent is not None
                or body["root_id"] != self._generation(self.head_generation)["root_id"]
                or body["target_snapshot"] is not None
                or not isinstance(body["snapshot_generation"], int)
                or isinstance(body["snapshot_generation"], bool)
                or body["snapshot_generation"] != generation_id
            ):
                raise IntegrityError(f"invalid snapshot event at line {line_number}")
            name = body["snapshot_name"]
            self._validate_snapshot_name_from_journal(name, line_number)
            if name in self._state["snapshots"]:
                raise IntegrityError(f"duplicate snapshot name at line {line_number}")
            self._state["snapshots"][name] = {
                "generation_id": generation_id,
                "root_id": body["root_id"],
                "created_ns": body["timestamp_ns"],
            }
        elif operation == "delete_snapshot":
            if (
                generation_id != self.head_generation
                or parent is not None
                or body["root_id"] != self._generation(self.head_generation)["root_id"]
                or body["target_snapshot"] is not None
                or not isinstance(body["snapshot_generation"], int)
                or isinstance(body["snapshot_generation"], bool)
            ):
                raise IntegrityError(f"invalid snapshot deletion at line {line_number}")
            name = body["snapshot_name"]
            self._validate_snapshot_name_from_journal(name, line_number)
            snapshot = self._state["snapshots"].get(name)
            if snapshot is None or snapshot["generation_id"] != body["snapshot_generation"]:
                raise IntegrityError(f"invalid snapshot deletion target at line {line_number}")
            del self._state["snapshots"][name]
        elif operation == "rollback":
            self._require_new_generation(generation_id, parent, line_number)
            if body["snapshot_name"] is not None:
                raise IntegrityError(f"invalid rollback metadata at line {line_number}")
            name = body["target_snapshot"]
            self._validate_snapshot_name_from_journal(name, line_number)
            snapshot = self._state["snapshots"].get(name)
            if (
                snapshot is None
                or not isinstance(body["snapshot_generation"], int)
                or isinstance(body["snapshot_generation"], bool)
                or snapshot["generation_id"] != body["snapshot_generation"]
                or snapshot["root_id"] != body["root_id"]
            ):
                raise IntegrityError(f"invalid rollback target at line {line_number}")
            generation = self._generation_entry(
                generation_id, parent, body["root_id"], "rollback", body
            )
            self._state["generations"].append(generation)
            self._state["generation_by_id"][generation_id] = generation
            self._state["head_generation"] = generation_id
        else:
            raise IntegrityError(f"unknown journal operation at line {line_number}")
        self._state["sequence"] = expected_sequence
        self._state["last_checksum"] = checksum

    def _apply_compacted_base(
        self, body: dict[str, Any], checksum: str, line_number: int
    ) -> None:
        base = body["base_state"]
        if not isinstance(base, dict) or set(base) != {"generations", "snapshots"}:
            raise IntegrityError(f"invalid compacted base state at line {line_number}")
        entries = base["generations"]
        snapshots = base["snapshots"]
        if (
            not isinstance(entries, list)
            or not entries
            or len(entries) > _MAX_COMPACT_GENERATIONS
            or not isinstance(snapshots, dict)
            or not snapshots
            or len(snapshots) > _MAX_COMPACT_SNAPSHOTS
        ):
            raise IntegrityError(f"invalid compacted history size at line {line_number}")

        generations: list[dict[str, Any]] = []
        generation_by_id: dict[int, dict[str, Any]] = {}
        previous_id = 0
        for item in entries:
            if not isinstance(item, dict) or set(item) != {
                "generation_id",
                "parent_generation",
                "root_id",
                "operation",
                "created_ns",
            }:
                raise IntegrityError(f"invalid compacted generation at line {line_number}")
            generation_id = item["generation_id"]
            parent = item["parent_generation"]
            root_id = item["root_id"]
            created_ns = item["created_ns"]
            if (
                not isinstance(generation_id, int)
                or isinstance(generation_id, bool)
                or generation_id <= previous_id
                or not isinstance(root_id, str)
                or not _HEX.fullmatch(root_id)
                or not isinstance(item["operation"], str)
                or item["operation"] not in {"init", "write", "rollback"}
                or not isinstance(created_ns, int)
                or isinstance(created_ns, bool)
                or created_ns < 0
                or (
                    parent is not None
                    and (
                        not isinstance(parent, int)
                        or isinstance(parent, bool)
                        or parent < 1
                        or parent >= generation_id
                    )
                )
            ):
                raise IntegrityError(f"invalid compacted generation fields at line {line_number}")
            self._load_root(root_id)
            generation = dict(item)
            generations.append(generation)
            generation_by_id[generation_id] = generation
            previous_id = generation_id

        head = generations[-1]
        if (
            head["generation_id"] != body["generation_id"]
            or head["root_id"] != body["root_id"]
        ):
            raise IntegrityError(f"compacted head mismatch at line {line_number}")

        validated_snapshots: dict[str, dict[str, Any]] = {}
        for name, item in snapshots.items():
            self._validate_snapshot_name_from_journal(name, line_number)
            if not isinstance(item, dict) or set(item) != {
                "generation_id",
                "root_id",
                "created_ns",
            }:
                raise IntegrityError(f"invalid compacted snapshot at line {line_number}")
            generation_id = item["generation_id"]
            root_id = item["root_id"]
            created_ns = item["created_ns"]
            if not isinstance(generation_id, int) or isinstance(generation_id, bool):
                raise IntegrityError(f"invalid compacted snapshot fields at line {line_number}")
            generation = generation_by_id.get(generation_id)
            if (
                generation is None
                or root_id != generation["root_id"]
                or not isinstance(created_ns, int)
                or isinstance(created_ns, bool)
                or created_ns < 0
            ):
                raise IntegrityError(f"invalid compacted snapshot fields at line {line_number}")
            validated_snapshots[name] = dict(item)

        self._state["generations"] = generations
        self._state["generation_by_id"] = generation_by_id
        self._state["snapshots"] = validated_snapshots
        self._state["head_generation"] = head["generation_id"]
        self._state["sequence"] = body["sequence"]
        self._state["last_checksum"] = checksum

    def _require_new_generation(
        self, generation_id: int, parent: Any, line_number: int
    ) -> None:
        if (
            not self._state["generations"]
            or not isinstance(parent, int)
            or isinstance(parent, bool)
            or parent != self.head_generation
            or generation_id != self.head_generation + 1
        ):
            raise IntegrityError(f"invalid generation transition at line {line_number}")

    @staticmethod
    def _validate_snapshot_name_from_journal(name: Any, line_number: int) -> None:
        try:
            SnapCoreVolume._validate_snapshot_name(name)
        except (TypeError, ValueError) as exc:
            raise IntegrityError(f"invalid snapshot name at line {line_number}") from exc

    def _generation_entry(
        self,
        generation_id: int,
        parent: Optional[int],
        root_id: str,
        operation: str,
        body: dict[str, Any],
    ) -> dict[str, Any]:
        return {
            "generation_id": generation_id,
            "parent_generation": parent,
            "root_id": root_id,
            "operation": operation,
            "created_ns": body["timestamp_ns"],
        }

    def _generation(self, generation_id: int) -> dict[str, Any]:
        try:
            return self._state["generation_by_id"][generation_id]
        except KeyError as exc:
            raise IntegrityError(f"journal references missing generation {generation_id}") from exc

    def _load_root(self, root_id: str) -> dict[str, str]:
        if not _HEX.fullmatch(root_id):
            raise IntegrityError("invalid mapping root identifier")
        data = _read_regular(self.root / "roots" / f"{root_id}.json", 16 * 1024 * 1024)
        document = _decode_json(data, f"mapping root {root_id}")
        if (
            not isinstance(document, dict)
            or set(document) != {"format_version", "blocks"}
            or document["format_version"] != FORMAT_VERSION
            or not isinstance(document["blocks"], dict)
        ):
            raise IntegrityError(f"invalid mapping root {root_id}")
        if self._root_id(document) != root_id:
            raise IntegrityError(f"mapping root checksum mismatch: {root_id}")
        blocks = document["blocks"]
        block_count = self.size_bytes // self.block_size
        for key, extent_id in blocks.items():
            if (
                not isinstance(key, str)
                or not key.isascii()
                or not key.isdigit()
                or str(int(key)) != key
                or int(key) < 0
                or int(key) >= block_count
                or not isinstance(extent_id, str)
                or not _HEX.fullmatch(extent_id)
            ):
                raise IntegrityError(f"invalid block mapping in root {root_id}")
        return blocks

    def _verify_root(self, root_id: str, *, verify_extents: bool) -> dict[str, str]:
        blocks = self._load_root(root_id)
        if verify_extents:
            for extent_id in blocks.values():
                self._read_extent(extent_id)
        return blocks

    def _read_extent(self, extent_id: str) -> bytes:
        if not _HEX.fullmatch(extent_id):
            raise IntegrityError("invalid extent identifier")
        data = _read_regular(
            self.root / "extents" / f"{extent_id}.blk", self.block_size
        )
        if len(data) != self.block_size or _sha256(data) != extent_id:
            raise IntegrityError(f"extent integrity mismatch: {extent_id}")
        return data

    def _store_extent(self, data: bytes) -> str:
        if len(data) != self.block_size:
            raise ValueError("extent data has the wrong block size")
        extent_id = _sha256(data)
        path = self.root / "extents" / f"{extent_id}.blk"
        created = _write_immutable(
            path,
            data,
            self.root / "extents",
            fault_hook=self._fault_hook,
            fault_point="extent",
        )
        if created:
            self._fault("extent_fsync")
        return extent_id

    def _store_root(self, root_id: str, document: dict[str, Any]) -> None:
        if self._root_id(document) != root_id:
            raise IntegrityError("refusing to store a mapping root with the wrong hash")
        path = self.root / "roots" / f"{root_id}.json"
        created = _write_immutable(
            path,
            _canonical(document) + b"\n",
            self.root / "roots",
            fault_hook=self._fault_hook,
            fault_point="root",
        )
        if created:
            self._fault("root_fsync")

    def _replace_journal(self, encoded: bytes, record: dict[str, Any]) -> None:
        temporary = self.root / f".journal.pending-{uuid.uuid4().hex}"
        fd = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | _NOFOLLOW,
            0o600,
        )
        try:
            _write_all(fd, encoded)
            self._fault("compact_journal_write")
            os.fsync(fd)
            self._fault("compact_journal_fsync")
        finally:
            os.close(fd)

        # The rename is the point after which replay may select the compacted
        # history. Block all access until the directory entry is synced and the
        # in-memory state has been rebuilt from the new anchor record.
        self._poisoned = True
        try:
            os.replace(temporary, self.root / "journal.log")
            self._fault("compact_journal_replace")
            _fsync_directory(self.root)
            self._fault("compact_journal_directory_fsync")
            self._poisoned = False
            self._load_format()
            self._apply_record(record, 1)
        except BaseException:
            self._poisoned = True
            raise

    def _append_event(
        self,
        *,
        operation: str,
        generation_id: int,
        parent_generation: Optional[int],
        root_id: str,
        snapshot_name: Optional[str] = None,
        target_snapshot: Optional[str] = None,
        snapshot_generation: Optional[int] = None,
    ) -> None:
        body = {
            "sequence": self._state["sequence"] + 1,
            "operation": operation,
            "volume_id": self.volume_id,
            "previous_checksum": self._state["last_checksum"],
            "timestamp_ns": time.time_ns(),
            "generation_id": generation_id,
            "parent_generation": parent_generation,
            "root_id": root_id,
            "snapshot_name": snapshot_name,
            "target_snapshot": target_snapshot,
            "snapshot_generation": snapshot_generation,
        }
        record = {"body": body, "checksum": _sha256(_canonical(body))}
        encoded = _canonical(record) + b"\n"
        if len(encoded) > _MAX_RECORD_SIZE:
            raise SnapCoreError("journal event exceeds prototype record limit")
        fd = os.open(
            self.root / "journal.log", os.O_WRONLY | os.O_APPEND | _NOFOLLOW
        )
        try:
            try:
                if self._fault_hook is not None:
                    partial = encoded[: max(1, len(encoded) // 2)]
                    _write_all(fd, partial)
                    self._fault("journal_partial")
                    _write_all(fd, encoded[len(partial) :])
                else:
                    _write_all(fd, encoded)
                self._fault("journal_append")
                os.fsync(fd)
                self._fault("journal_fsync")
                self._apply_record(record, body["sequence"])
            except BaseException:
                # A failed append/fsync leaves commit status uncertain. This
                # instance must not append using stale in-memory sequence data;
                # close and replay the journal before accepting more work.
                self._poisoned = True
                raise
        finally:
            try:
                os.close(fd)
            except OSError:
                self._poisoned = True
                raise

    def _fault(self, point: str) -> None:
        if self._fault_hook is not None:
            self._fault_hook(point)
