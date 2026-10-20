#!/usr/bin/env python3
"""Rootless integrity, CoW history, rollback and crash-replay tests."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from snapcore import IntegrityError, SnapCoreError, SnapCoreVolume


class SnapCoreTests(unittest.TestCase):
    block_size = 16

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="veyra-snapcore-")
        self.addCleanup(self.temp.cleanup)
        self.store = Path(self.temp.name) / "volume"
        self.volume = SnapCoreVolume.format(
            self.store, size_bytes=8 * self.block_size, block_size=self.block_size
        )
        self.addCleanup(self.volume.close)

    def reopen(self) -> SnapCoreVolume:
        self.volume.close()
        self.volume = SnapCoreVolume.open(self.store)
        return self.volume

    def test_sparse_partial_writes_and_bounds(self) -> None:
        self.assertEqual(self.volume.read(0, 4 * self.block_size), bytes(4 * self.block_size))
        self.volume.write(3, b"abc")
        self.assertEqual(self.volume.read(0, 8), b"\0\0\0abc\0\0")
        self.volume.write(self.block_size - 2, b"WXYZ")
        expected = bytearray(2 * self.block_size)
        expected[3:6] = b"abc"
        expected[self.block_size - 2 : self.block_size + 2] = b"WXYZ"
        self.assertEqual(self.volume.read(0, len(expected)), bytes(expected))
        with self.assertRaises(ValueError):
            self.volume.write(self.volume.size_bytes, b"x")
        with self.assertRaises(ValueError):
            self.volume.read(self.volume.size_bytes, 1)

    def test_snapshot_fork_preserves_generations_and_rollback_creates_new_head(self) -> None:
        self.volume.write(0, b"before")
        first = self.volume.snapshot("known-good")
        original_generation = first["generation_id"]
        original_root = first["root_id"]
        original_extent = self.volume._load_root(original_root)["0"]

        self.volume.write(0, b"broken!")
        damaged_generation = self.volume.head_generation
        damaged = self.volume.snapshot("damaged")
        damaged_extent = self.volume._load_root(damaged["root_id"])["0"]
        self.assertNotEqual(original_root, damaged["root_id"])
        self.assertNotEqual(original_extent, damaged_extent)
        self.assertEqual(self.volume._read_extent(original_extent), b"before" + bytes(10))
        self.assertEqual(self.volume._read_extent(damaged_extent), b"broken!" + bytes(9))
        self.assertEqual(self.volume.read(0, 7), b"broken!")

        first_restore = self.volume.rollback("known-good")
        self.assertGreater(first_restore, damaged_generation)
        self.assertEqual(self.volume.read(0, 7), b"before\0")
        damaged_restore = self.volume.rollback("damaged")
        self.assertGreater(damaged_restore, first_restore)
        self.assertEqual(self.volume.read(0, 7), b"broken!")
        restored_generation = self.volume.rollback("known-good")
        self.assertGreater(restored_generation, damaged_restore)
        self.assertEqual(self.volume.read(0, 7), b"before\0")
        self.assertEqual(self.volume.snapshots(verify=True), sorted(
            self.volume.snapshots(), key=lambda item: item["name"]
        ))
        self.assertEqual(
            next(s for s in self.volume.snapshots() if s["name"] == "known-good")["root_id"],
            original_root,
        )
        generations = self.volume.generations()
        self.assertEqual([g["generation_id"] for g in generations], list(range(1, restored_generation + 1)))
        self.assertEqual(generations[-1]["operation"], "rollback")
        self.assertEqual(generations[-1]["parent_generation"], damaged_restore)
        self.assertEqual(
            self.volume.verify()["generations"],
            len(generations),
        )

        self.volume.write(0, b"new-head")
        self.assertEqual(self.volume.read(0, 8), b"new-head")
        self.assertEqual(self.volume._load_root(original_root), {"0": hashlib.sha256(b"before" + bytes(10)).hexdigest()})
        self.reopen()
        self.assertEqual(self.volume.read(0, 8), b"new-head")
        self.assertEqual(len(self.volume.snapshots(verify=True)), 2)

    def test_snapshot_names_and_duplicate_names_fail_safely(self) -> None:
        for invalid in ("", ".", "..", "../escape", "has space", "slash/name"):
            with self.subTest(name=invalid), self.assertRaises(ValueError):
                self.volume.snapshot(invalid)
        self.volume.snapshot("base-1")
        with self.assertRaises(SnapCoreError):
            self.volume.snapshot("base-1")
        with self.assertRaises(SnapCoreError):
            self.volume.rollback("missing")

    def test_cli_round_trip(self) -> None:
        store = Path(self.temp.name) / "cli-volume"

        def run(*arguments: str) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "veyra-snapcore.py"),
                    *arguments,
                ],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

        run("format", str(store), "--size-bytes", "64", "--block-size", "16")
        run("write", str(store), "0", "616263")
        run("snapshot", str(store), "before")
        run("write", str(store), "0", "78797a")
        run("rollback", str(store), "before")
        self.assertEqual(run("read", str(store), "0", "3").stdout.strip(), "616263")
        status = json.loads(run("status", str(store), "--verify").stdout)
        self.assertEqual(status["head_generation"], 4)
        self.assertEqual(len(status["snapshots"]), 1)

    def test_extent_corruption_is_detected_before_restore_is_offered(self) -> None:
        self.volume.write(0, b"important")
        self.volume.snapshot("good")
        extent_id = self.volume._load_root(
            self.volume._generation(self.volume.head_generation)["root_id"]
        )["0"]
        self.volume.close()
        extent_path = self.store / "extents" / f"{extent_id}.blk"
        extent_path.write_bytes(b"tampered extent")
        self.volume = None  # avoid cleanup on the already closed instance
        with SnapCoreVolume.open(self.store) as reopened:
            with self.assertRaises(IntegrityError):
                reopened.snapshots(verify=True)
            with self.assertRaises(IntegrityError):
                reopened.verify()
            with self.assertRaises(IntegrityError):
                reopened.read(0, 1)

    def test_snapshot_refuses_corrupt_head_without_appending_checkpoint(self) -> None:
        self.volume.write(0, b"damaged")
        root_id = self.volume._generation(self.volume.head_generation)["root_id"]
        extent_id = self.volume._load_root(root_id)["0"]
        self.volume.close()
        (self.store / "extents" / f"{extent_id}.blk").write_bytes(b"corrupt")
        self.volume = None

        with SnapCoreVolume.open(self.store) as reopened:
            journal_size = (self.store / "journal.log").stat().st_size
            head = reopened.head_generation
            with self.assertRaises(IntegrityError):
                reopened.snapshot("must-not-commit")
            self.assertEqual(reopened.head_generation, head)
            self.assertEqual(reopened.snapshots(), [])
            self.assertEqual((self.store / "journal.log").stat().st_size, journal_size)

    def test_rollback_refuses_corrupt_snapshot_without_changing_head(self) -> None:
        self.volume.write(0, b"last-known-good")
        saved = self.volume.snapshot("good")
        self.volume.write(0, b"damaged-state")
        damaged_generation = self.volume.head_generation
        extent_id = self.volume._load_root(saved["root_id"])["0"]
        self.volume.close()
        (self.store / "extents" / f"{extent_id}.blk").write_bytes(b"corrupt")
        self.volume = None

        with SnapCoreVolume.open(self.store) as reopened:
            journal_size = (self.store / "journal.log").stat().st_size
            with self.assertRaises(IntegrityError):
                reopened.rollback("good")
            self.assertEqual(reopened.head_generation, damaged_generation)
            self.assertEqual(reopened.read(0, 13), b"damaged-state")
            self.assertEqual((self.store / "journal.log").stat().st_size, journal_size)
            with self.assertRaises(IntegrityError):
                reopened.snapshots(verify=True)

    def test_process_crash_during_snapshot_or_rollback_replays_atomically(self) -> None:
        snapshot_script = (
            "import os,sys; "
            "from snapcore import SnapCoreVolume; "
            "v=SnapCoreVolume.open(sys.argv[1], "
            "_fault_hook=lambda point: os._exit(88) if point == sys.argv[2] else None); "
            "v.snapshot('checkpoint'); os._exit(0)"
        )
        rollback_script = (
            "import os,sys; "
            "from snapcore import SnapCoreVolume; "
            "v=SnapCoreVolume.open(sys.argv[1], "
            "_fault_hook=lambda point: os._exit(89) if point == sys.argv[2] else None); "
            "v.rollback('last-known-good'); os._exit(0)"
        )
        for point in ("journal_partial", "journal_append", "journal_fsync"):
            with self.subTest(operation="snapshot", point=point), tempfile.TemporaryDirectory(
                prefix="veyra-snapcore-snapshot-crash-"
            ) as temp:
                store = Path(temp) / "volume"
                with SnapCoreVolume.format(
                    store, size_bytes=8 * self.block_size, block_size=self.block_size
                ) as baseline:
                    baseline.write(0, b"baseline")
                    head = baseline.head_generation
                child = subprocess.run(
                    [sys.executable, "-c", snapshot_script, str(store), point],
                    cwd=ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(child.returncode, 88, child.stderr)
                with SnapCoreVolume.open(store) as recovered:
                    self.assertEqual(recovered.head_generation, head)
                    names = {item["name"] for item in recovered.snapshots(verify=True)}
                    if point == "journal_partial":
                        self.assertEqual(names, set())
                    else:
                        self.assertIn(names, (set(), {"checkpoint"}))
                    self.assertEqual(recovered.read(0, 8), b"baseline")
                    recovered.write(0, b"continued")
                    recovered.verify()

            with self.subTest(operation="rollback", point=point), tempfile.TemporaryDirectory(
                prefix="veyra-snapcore-rollback-crash-"
            ) as temp:
                store = Path(temp) / "volume"
                with SnapCoreVolume.format(
                    store, size_bytes=8 * self.block_size, block_size=self.block_size
                ) as baseline:
                    baseline.write(0, b"last-known-good")
                    baseline.snapshot("last-known-good")
                    baseline.write(0, b"damaged-state")
                    old_head = baseline.head_generation
                child = subprocess.run(
                    [sys.executable, "-c", rollback_script, str(store), point],
                    cwd=ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(child.returncode, 89, child.stderr)
                with SnapCoreVolume.open(store) as recovered:
                    if point == "journal_partial":
                        self.assertEqual(recovered.head_generation, old_head)
                        self.assertEqual(recovered.read(0, 13), b"damaged-state")
                    else:
                        self.assertIn(recovered.head_generation, (old_head, old_head + 1))
                        self.assertIn(
                            recovered.read(0, 15),
                            (b"damaged-stateod", b"last-known-good"),
                        )
                        if point == "journal_fsync":
                            self.assertEqual(recovered.head_generation, old_head + 1)
                            self.assertEqual(recovered.read(0, 15), b"last-known-good")
                    self.assertEqual(len(recovered.snapshots(verify=True)), 1)
                    recovered.verify()
                    recovered.write(0, b"recovered")
                    recovered.verify()

    def test_mapping_root_corruption_fails_closed_on_open(self) -> None:
        self.volume.write(0, b"data")
        root_id = self.volume._generation(self.volume.head_generation)["root_id"]
        self.volume.close()
        (self.store / "roots" / f"{root_id}.json").write_bytes(b"{}")
        self.volume = None
        with self.assertRaises(IntegrityError):
            SnapCoreVolume.open(self.store)

    def test_complete_journal_corruption_fails_closed(self) -> None:
        self.volume.write(0, b"data")
        self.volume.close()
        journal = self.store / "journal.log"
        lines = journal.read_bytes().splitlines()
        record = json.loads(lines[-1])
        record["checksum"] = "0" * 64
        lines[-1] = json.dumps(record, sort_keys=True, separators=(",", ":")).encode()
        journal.write_bytes(b"\n".join(lines) + b"\n")
        self.volume = None
        with self.assertRaises(IntegrityError):
            SnapCoreVolume.open(self.store)

    def test_truncated_journal_tail_is_discarded_then_writes_continue(self) -> None:
        self.volume.write(0, b"stable")
        self.volume.snapshot("stable")
        self.volume.close()
        journal = self.store / "journal.log"
        valid_size = journal.stat().st_size
        with journal.open("ab") as stream:
            stream.write(b'{"incomplete":')
        self.volume = None

        reopened = SnapCoreVolume.open(self.store)
        self.volume = reopened
        self.assertEqual(journal.stat().st_size, valid_size)
        self.assertEqual(self.volume.read(0, 6), b"stable")
        self.volume.write(0, b"next")
        self.volume.close()
        self.volume = None
        with SnapCoreVolume.open(self.store) as recovered:
            self.assertEqual(recovered.read(0, 6), b"nextle")
            self.assertEqual(len(recovered.snapshots(verify=True)), 1)
            recovered.verify()

    def test_process_crash_boundaries_replay_to_a_valid_generation(self) -> None:
        script = (
            "import os,sys; "
            "from snapcore import SnapCoreVolume; "
            "point=sys.argv[2]; "
            "v=SnapCoreVolume.open(sys.argv[1], "
            "_fault_hook=lambda current: os._exit(86) if current == point else None); "
            "v.write(0,b'new-state'); "
            "os._exit(0)"
        )
        for point, expected in (
            ("extent_temp", b"old-state"),
            ("extent_fsync", b"old-state"),
            ("root_temp", b"old-state"),
            ("root_fsync", b"old-state"),
            ("journal_partial", b"old-state"),
            ("journal_append", None),
            ("journal_fsync", b"new-state"),
        ):
            with self.subTest(point=point), tempfile.TemporaryDirectory(
                prefix="veyra-snapcore-crash-"
            ) as temp:
                store = Path(temp) / "volume"
                with SnapCoreVolume.format(
                    store, size_bytes=8 * self.block_size, block_size=self.block_size
                ) as baseline:
                    baseline.write(0, b"old-state")
                    baseline.snapshot("last-known-good")

                child = subprocess.run(
                    [sys.executable, "-c", script, str(store), point],
                    cwd=ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(child.returncode, 86, child.stderr)
                with SnapCoreVolume.open(store) as recovered:
                    current = recovered.read(0, 9)
                    self.assertIn(current, (b"old-state", b"new-state"))
                    if expected is not None:
                        self.assertEqual(current, expected)
                    self.assertEqual(len(recovered.snapshots(verify=True)), 1)
                    recovered.verify()
                    recovered.write(0, b"new-state")
                    self.assertEqual(recovered.read(0, 9), b"new-state")
                    generation_before_rollback = recovered.head_generation
                    restored = recovered.rollback("last-known-good")
                    self.assertGreater(restored, generation_before_rollback)
                    self.assertEqual(recovered.read(0, 9), b"old-state")
                with SnapCoreVolume.open(store) as reopened:
                    self.assertEqual(reopened.read(0, 9), b"old-state")
                    reopened.verify()

    def test_crash_after_first_extent_of_multiblock_write_keeps_old_head(self) -> None:
        script = (
            "import os,sys; "
            "from snapcore import SnapCoreVolume; "
            "v=SnapCoreVolume.open(sys.argv[1], "
            "_fault_hook=lambda point: os._exit(87) if point == 'extent_fsync' else None); "
            "v.write(0, bytes.fromhex(sys.argv[2])); "
            "os._exit(0)"
        )
        with tempfile.TemporaryDirectory(prefix="veyra-snapcore-multiblock-") as temp:
            store = Path(temp) / "volume"
            with SnapCoreVolume.format(
                store, size_bytes=8 * self.block_size, block_size=self.block_size
            ) as baseline:
                baseline.write(0, b"old-state")
                baseline.snapshot("last-known-good")
                old_head = baseline.head_generation

            payload = bytes(range(2 * self.block_size))
            child = subprocess.run(
                [sys.executable, "-c", script, str(store), payload.hex()],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(child.returncode, 87, child.stderr)
            with SnapCoreVolume.open(store) as recovered:
                self.assertEqual(recovered.head_generation, old_head)
                self.assertEqual(recovered.read(0, 9), b"old-state")
                self.assertEqual(len(recovered.generations()), old_head)
                self.assertEqual(len(recovered.snapshots(verify=True)), 1)
                recovered.verify()


if __name__ == "__main__":
    unittest.main(verbosity=2)
