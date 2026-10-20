#!/usr/bin/env python3
"""Rootless integrity, CoW history, rollback and crash-replay tests."""

from __future__ import annotations

import hashlib
import json
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import threading
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
        self.addCleanup(self.volume.close)
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

    def test_deterministic_operation_history_matches_reference_volume(self) -> None:
        randomizer = random.Random(0x5A17)
        expected = bytearray(self.volume.size_bytes)
        retained: dict[str, bytes] = {}

        for step in range(160):
            operation = randomizer.randrange(12)
            if operation < 6 or not retained:
                offset = randomizer.randrange(self.volume.size_bytes)
                limit = min(64, self.volume.size_bytes - offset)
                payload = bytes(
                    randomizer.randrange(256)
                    for _ in range(randomizer.randrange(1, limit + 1))
                )
                previous_generation = self.volume.head_generation
                self.volume.write(offset, payload)
                expected[offset : offset + len(payload)] = payload
                self.assertEqual(self.volume.head_generation, previous_generation + 1)
            elif operation < 8 and len(retained) < 12:
                name = f"generated-{step}"
                previous_generation = self.volume.head_generation
                self.volume.snapshot(name)
                retained[name] = bytes(expected)
                self.assertEqual(self.volume.head_generation, previous_generation)
            elif operation < 10:
                name = randomizer.choice(sorted(retained))
                previous_generation = self.volume.head_generation
                self.volume.rollback(name)
                expected = bytearray(retained[name])
                self.assertEqual(self.volume.head_generation, previous_generation + 1)
            else:
                name = randomizer.choice(sorted(retained))
                previous_generation = self.volume.head_generation
                self.volume.delete_snapshot(name)
                del retained[name]
                self.assertEqual(self.volume.head_generation, previous_generation)

            self.assertEqual(self.volume.read(0, len(expected)), bytes(expected))
            if step % 32 == 0:
                self.volume.verify()
            if step in (63, 127):
                self.volume.collect_garbage()
            if step in (31, 79, 127):
                self.reopen()
                self.assertEqual(self.volume.read(0, len(expected)), bytes(expected))

        self.assertEqual(
            {item["name"] for item in self.volume.snapshots(verify=True)},
            set(retained),
        )
        for name, contents in sorted(retained.items()):
            self.volume.rollback(name)
            self.assertEqual(self.volume.read(0, len(contents)), contents)
        self.volume.verify()

    def test_seeded_prune_gc_histories_match_reference_volume(self) -> None:
        for seed in range(0xC0A1, 0xC0B1):
            with self.subTest(seed=seed), tempfile.TemporaryDirectory(
                prefix="veyra-snapcore-model-"
            ) as temp:
                store = Path(temp) / "volume"
                volume = SnapCoreVolume.format(
                    store,
                    size_bytes=8 * self.block_size,
                    block_size=self.block_size,
                )
                expected = bytearray(volume.size_bytes)
                retained: dict[str, bytes] = {}
                anchor = f"anchor-{seed:x}"
                volume.snapshot(anchor)
                retained[anchor] = bytes(expected)
                randomizer = random.Random(seed)

                def assert_matches_model() -> None:
                    self.assertEqual(volume.read(0, len(expected)), bytes(expected))
                    snapshots = {
                        item["name"]: item for item in volume.snapshots(verify=True)
                    }
                    self.assertEqual(set(snapshots), set(retained))
                    generation_ids = {
                        item["generation_id"] for item in volume.generations()
                    }
                    self.assertIn(volume.head_generation, generation_ids)
                    for generation in volume.generations():
                        parent = generation["parent_generation"]
                        self.assertTrue(parent is None or parent in generation_ids)
                    for name, contents in retained.items():
                        snapshot = snapshots[name]
                        self.assertIn(snapshot["generation_id"], generation_ids)
                        mapping = volume._load_root(snapshot["root_id"])
                        restored = bytearray(volume.size_bytes)
                        for block, extent_id in mapping.items():
                            start = int(block) * volume.block_size
                            restored[start : start + volume.block_size] = (
                                volume._read_extent(extent_id)
                            )
                        self.assertEqual(bytes(restored), contents, name)

                try:
                    for step in range(96):
                        operation = randomizer.randrange(10)
                        if operation < 5:
                            offset = randomizer.randrange(volume.size_bytes)
                            limit = min(48, volume.size_bytes - offset)
                            payload = bytes(
                                0 if randomizer.randrange(5) == 0 else randomizer.randrange(256)
                                for _ in range(randomizer.randrange(1, limit + 1))
                            )
                            volume.write(offset, payload)
                            expected[offset : offset + len(payload)] = payload
                        elif operation == 5 and len(retained) < 8:
                            name = f"seed-{seed:x}-{step}"
                            volume.snapshot(name)
                            retained[name] = bytes(expected)
                        elif operation == 6:
                            name = randomizer.choice(sorted(retained))
                            volume.rollback(name)
                            expected = bytearray(retained[name])
                        elif operation == 7 and len(retained) > 1:
                            name = randomizer.choice(sorted(retained))
                            volume.delete_snapshot(name)
                            del retained[name]
                        elif operation == 8:
                            volume.prune_generations(randomizer.randrange(1, 5))
                        elif operation == 9:
                            volume.collect_garbage()

                        assert_matches_model()
                        if step % 24 == 23:
                            volume.close()
                            volume = SnapCoreVolume.open(store)
                            assert_matches_model()
                        if step % 16 == 15:
                            volume.verify()
                finally:
                    volume.close()

    def test_shared_handle_serializes_threaded_partial_writes_and_reads(self) -> None:
        writer_count = 4
        writes_per_writer = 60
        barrier = threading.Barrier(writer_count + 2)

        def writer(index: int) -> None:
            barrier.wait(timeout=10)
            value = bytes([ord("A") + index])
            for _ in range(writes_per_writer):
                self.volume.write(index, value)

        def reader() -> None:
            barrier.wait(timeout=10)
            allowed = {0, *(ord("A") + index for index in range(writer_count))}
            for _ in range(300):
                observed = self.volume.read(0, writer_count)
                self.assertEqual(len(observed), writer_count)
                self.assertTrue(set(observed).issubset(allowed), observed)

        def checkpoint_writer() -> None:
            barrier.wait(timeout=10)
            for index in range(6):
                self.volume.snapshot(f"thread-checkpoint-{index}")

        with ThreadPoolExecutor(max_workers=writer_count + 2) as workers:
            futures = [workers.submit(writer, index) for index in range(writer_count)]
            futures.extend((workers.submit(reader), workers.submit(checkpoint_writer)))
            for future in futures:
                future.result(timeout=30)

        self.assertEqual(self.volume.read(0, writer_count), b"ABCD")
        self.assertEqual(
            self.volume.head_generation,
            1 + writer_count * writes_per_writer,
        )
        self.assertEqual(len(self.volume.snapshots(verify=True)), 6)
        self.volume.verify()

    def test_independent_writers_serialize_on_the_volume_lock(self) -> None:
        self.volume.close()
        self.volume = None
        script = (
            "import sys,time; "
            "from snapcore import SnapCoreVolume; "
            "with_error=False; "
            "v=SnapCoreVolume.open(sys.argv[1]); "
            "time.sleep(0.25); "
            "generation=v.write(0, bytes.fromhex(sys.argv[2])); "
            "print(generation); v.close()"
        )
        commands = [
            [sys.executable, "-c", script, str(self.store), (bytes([value]) * 8).hex()]
            for value in (ord("A"), ord("B"))
        ]
        processes = [
            subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            for command in commands
        ]
        results = [process.communicate(timeout=10) + (process.returncode,) for process in processes]
        for stdout, stderr, returncode in results:
            self.assertEqual(returncode, 0, stderr)
            self.assertIn(stdout.strip(), {"2", "3"})

        with SnapCoreVolume.open(self.store) as recovered:
            self.assertEqual(recovered.head_generation, 3)
            self.assertEqual([item["generation_id"] for item in recovered.generations()], [1, 2, 3])
            self.assertIn(recovered.read(0, 8), (b"A" * 8, b"B" * 8))
            recovered.verify()

    def test_snapshot_names_and_duplicate_names_fail_safely(self) -> None:
        for invalid in ("", ".", "..", "../escape", "has space", "slash/name"):
            with self.subTest(name=invalid), self.assertRaises(ValueError):
                self.volume.snapshot(invalid)
        self.volume.snapshot("base-1")
        with self.assertRaises(SnapCoreError):
            self.volume.snapshot("base-1")
        with self.assertRaises(SnapCoreError):
            self.volume.rollback("missing")

    def test_delete_and_gc_keep_every_retained_generation_recoverable(self) -> None:
        self.volume.write(0, b"generation-one")
        self.volume.snapshot("keep")
        self.volume.write(0, b"generation-two")
        deleted_snapshot = self.volume.snapshot("remove-me")
        self.volume.write(0, b"current-head")
        generation_count = len(self.volume.generations())
        deleted_generation_root = deleted_snapshot["root_id"]

        orphan_extent = self.volume._store_extent(b"orphan" + bytes(self.block_size - 6))
        orphan_root = self.volume._root_document({"3": orphan_extent})
        orphan_root_id = self.volume._root_id(orphan_root)
        self.volume._store_root(orphan_root_id, orphan_root)
        pending_extent = self.store / "extents" / (".pending-" + "a" * 32)
        pending_extent.write_bytes(b"unfinished")

        head_before_delete = self.volume.head_generation
        self.volume.delete_snapshot("remove-me")
        self.assertEqual(self.volume.head_generation, head_before_delete)
        self.assertEqual({item["name"] for item in self.volume.snapshots()}, {"keep"})
        with self.assertRaises(SnapCoreError):
            self.volume.rollback("remove-me")

        collected = self.volume.collect_garbage()
        self.assertEqual(collected["removed_roots"], 1)
        self.assertEqual(collected["removed_extents"], 1)
        self.assertEqual(collected["removed_extent_temps"], 1)
        self.assertEqual(collected["removed_root_temps"], 0)
        self.assertFalse((self.store / "roots" / f"{orphan_root_id}.json").exists())
        self.assertFalse((self.store / "extents" / f"{orphan_extent}.blk").exists())

        self.assertEqual(len(self.volume.generations()), generation_count)
        self.assertTrue((self.store / "roots" / f"{deleted_generation_root}.json").exists())
        self.volume.verify()
        self.assertEqual(self.volume.read(0, 12), b"current-head")
        self.assertEqual(self.volume.rollback("keep"), head_before_delete + 1)
        self.assertEqual(self.volume.read(0, 14), b"generation-one")
        self.reopen()
        self.volume.verify()
        self.assertEqual(len(self.volume.generations()), generation_count + 1)
        self.assertEqual(self.volume.read(0, 14), b"generation-one")

    def test_prune_compacts_history_and_preserves_head_and_checkpoints(self) -> None:
        self.volume.write(0, b"safe")
        good = self.volume.snapshot("good")
        self.volume.write(0, b"stale")
        stale_generation = self.volume.head_generation
        stale_root = self.volume._generation(stale_generation)["root_id"]
        self.volume.write(0, b"head")
        current = self.volume.snapshot("current")
        self.volume.write(0, b"latest")
        active_generation = self.volume.head_generation

        result = self.volume.prune_generations(1)
        retained_ids = [item["generation_id"] for item in self.volume.generations()]
        self.assertEqual(result["removed_generations"], 2)
        self.assertEqual(
            retained_ids,
            [good["generation_id"], current["generation_id"], active_generation],
        )
        retained_set = set(retained_ids)
        self.assertTrue(
            all(
                item["parent_generation"] is None
                or item["parent_generation"] in retained_set
                for item in self.volume.generations()
            )
        )
        self.assertEqual(self.volume.head_generation, active_generation)
        self.assertEqual(self.volume.read(0, 6), b"latest")
        self.assertEqual(
            {item["name"] for item in self.volume.snapshots(verify=True)},
            {"good", "current"},
        )
        self.assertTrue((self.store / "roots" / f"{stale_root}.json").exists())

        collected = self.volume.collect_garbage()
        self.assertGreaterEqual(collected["removed_roots"], 1)
        self.assertFalse((self.store / "roots" / f"{stale_root}.json").exists())
        self.volume.verify()
        self.reopen()
        self.assertEqual(
            [item["generation_id"] for item in self.volume.generations()], retained_ids
        )
        self.assertEqual(self.volume.rollback("good"), active_generation + 1)
        self.assertEqual(self.volume.read(0, 4), b"safe")
        self.volume.verify()

    def test_prune_requires_checkpoint_and_protects_the_last_checkpoint(self) -> None:
        original_generations = self.volume.generations()
        with self.assertRaisesRegex(SnapCoreError, "named recovery checkpoint"):
            self.volume.prune_generations(1)
        self.assertEqual(self.volume.generations(), original_generations)
        for invalid in (0, -1, True, 1.5):
            with self.subTest(keep_last=invalid), self.assertRaises(ValueError):
                self.volume.prune_generations(invalid)

        self.volume.write(0, b"known-good")
        self.volume.snapshot("only-checkpoint")
        with self.assertRaisesRegex(SnapCoreError, "last named recovery checkpoint"):
            self.volume.delete_snapshot("only-checkpoint")
        self.assertEqual(
            [item["name"] for item in self.volume.snapshots(verify=True)],
            ["only-checkpoint"],
        )

    def test_prune_compaction_recovers_after_process_crash(self) -> None:
        script = (
            "import os,sys; "
            "from snapcore import SnapCoreVolume; "
            "v=SnapCoreVolume.open(sys.argv[1], "
            "_fault_hook=lambda point: os._exit(96) if point == sys.argv[2] else None); "
            "v.prune_generations(1); os._exit(0)"
        )
        for point in (
            "compact_journal_fsync",
            "compact_journal_replace",
            "compact_journal_directory_fsync",
        ):
            with self.subTest(point=point), tempfile.TemporaryDirectory(
                prefix="veyra-snapcore-prune-crash-"
            ) as temp:
                store = Path(temp) / "volume"
                with SnapCoreVolume.format(
                    store, size_bytes=8 * self.block_size, block_size=self.block_size
                ) as baseline:
                    baseline.write(0, b"safe")
                    baseline.snapshot("good")
                    baseline.write(0, b"stale")
                    baseline.write(0, b"head")
                    original_count = len(baseline.generations())

                child = subprocess.run(
                    [sys.executable, "-c", script, str(store), point],
                    cwd=ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(child.returncode, 96, child.stderr)
                with SnapCoreVolume.open(store) as recovered:
                    ids = [item["generation_id"] for item in recovered.generations()]
                    if point == "compact_journal_fsync":
                        self.assertEqual(len(ids), original_count)
                    else:
                        self.assertEqual(len(ids), 2)
                    self.assertEqual(recovered.head_generation, 4)
                    self.assertEqual(recovered.read(0, 4), b"head")
                    self.assertEqual(recovered.snapshots(verify=True)[0]["name"], "good")
                    self.assertFalse(
                        any(path.name.startswith(".journal.pending-") for path in store.iterdir())
                    )
                    recovered.verify()

    def test_prune_uncertain_replace_requires_replay(self) -> None:
        self.volume.write(0, b"safe")
        self.volume.snapshot("good")
        self.volume.write(0, b"stale")
        self.volume.write(0, b"head")
        self.volume.close()
        self.volume = None

        def fail_after_replace(point: str) -> None:
            if point == "compact_journal_replace":
                raise OSError("injected journal replacement failure")

        volume = SnapCoreVolume.open(self.store, _fault_hook=fail_after_replace)
        with self.assertRaisesRegex(OSError, "injected journal replacement failure"):
            volume.prune_generations(1)
        with self.assertRaisesRegex(SnapCoreError, "close and reopen"):
            volume.read(0, 4)
        volume.close()

        with SnapCoreVolume.open(self.store) as recovered:
            self.assertEqual(len(recovered.generations()), 2)
            self.assertEqual(recovered.read(0, 4), b"head")
            self.assertEqual(recovered.snapshots(verify=True)[0]["name"], "good")
            recovered.verify()

    def test_compacted_journal_rejects_snapshot_to_missing_generation(self) -> None:
        self.volume.write(0, b"safe")
        self.volume.snapshot("good")
        self.volume.write(0, b"head")
        self.volume.prune_generations(1)
        self.volume.close()
        self.volume = None

        journal_path = self.store / "journal.log"
        record = json.loads(journal_path.read_text(encoding="ascii"))
        record["body"]["base_state"]["snapshots"]["good"]["generation_id"] = 999
        body = json.dumps(
            record["body"], sort_keys=True, separators=(",", ":"), ensure_ascii=True
        ).encode("ascii")
        record["checksum"] = hashlib.sha256(body).hexdigest()
        journal_path.write_text(
            json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
            + "\n",
            encoding="ascii",
        )
        with self.assertRaises(IntegrityError):
            SnapCoreVolume.open(self.store)

    def test_snapshot_deletion_journal_crashes_replay_atomically(self) -> None:
        script = (
            "import os,sys; "
            "from snapcore import SnapCoreVolume; "
            "v=SnapCoreVolume.open(sys.argv[1], "
            "_fault_hook=lambda point: os._exit(94) if point == sys.argv[2] else None); "
            "v.delete_snapshot('remove-me'); os._exit(0)"
        )
        for point in ("journal_partial", "journal_append", "journal_fsync"):
            with self.subTest(point=point), tempfile.TemporaryDirectory(
                prefix="veyra-snapcore-delete-crash-"
            ) as temp:
                store = Path(temp) / "volume"
                with SnapCoreVolume.format(
                    store, size_bytes=8 * self.block_size, block_size=self.block_size
                ) as baseline:
                    baseline.write(0, b"keep-current")
                    baseline.snapshot("retain-me")
                    baseline.snapshot("remove-me")
                    head = baseline.head_generation
                child = subprocess.run(
                    [sys.executable, "-c", script, str(store), point],
                    cwd=ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(child.returncode, 94, child.stderr)
                with SnapCoreVolume.open(store) as recovered:
                    names = {item["name"] for item in recovered.snapshots(verify=True)}
                    if point == "journal_partial":
                        self.assertEqual(names, {"retain-me", "remove-me"})
                    else:
                        self.assertIn(
                            names,
                            ({"retain-me"}, {"retain-me", "remove-me"}),
                        )
                    if point == "journal_fsync":
                        self.assertEqual(names, {"retain-me"})
                    self.assertEqual(recovered.head_generation, head)
                    self.assertEqual(recovered.read(0, 12), b"keep-current")
                    recovered.verify()

    def test_journal_io_failure_poison_instance_until_replay(self) -> None:
        for point in ("journal_partial", "journal_append", "journal_fsync"):
            with self.subTest(point=point), tempfile.TemporaryDirectory(
                prefix="veyra-snapcore-io-failure-"
            ) as temp:
                store = Path(temp) / "volume"
                with SnapCoreVolume.format(
                    store, size_bytes=8 * self.block_size, block_size=self.block_size
                ) as baseline:
                    baseline.write(0, b"committed")
                    baseline.snapshot("known-good")
                    previous_generation = baseline.head_generation

                def inject_io_error(current: str) -> None:
                    if current == point:
                        raise OSError("injected journal I/O failure")

                volume = SnapCoreVolume.open(store, _fault_hook=inject_io_error)
                with self.assertRaisesRegex(OSError, "injected journal I/O failure"):
                    volume.write(0, b"uncertain")
                blocked_operations = (
                    lambda: volume.write(0, b"must-not-append"),
                    lambda: volume.read(0, 1),
                    lambda: volume.head_generation,
                    lambda: volume.size_bytes,
                    lambda: volume.block_size,
                    lambda: volume.volume_id,
                    volume.generations,
                    volume.snapshots,
                )
                for operation in blocked_operations:
                    with self.assertRaisesRegex(SnapCoreError, "close and reopen"):
                        operation()
                volume.close()

                with SnapCoreVolume.open(store) as recovered:
                    recovered_state = (
                        recovered.head_generation,
                        recovered.read(0, 9),
                    )
                    self.assertIn(
                        recovered_state,
                        (
                            (previous_generation, b"committed"),
                            (previous_generation + 1, b"uncertain"),
                        ),
                    )
                    if point == "journal_partial":
                        self.assertEqual(
                            recovered_state,
                            (previous_generation, b"committed"),
                        )
                    elif point == "journal_fsync":
                        self.assertEqual(
                            recovered_state,
                            (previous_generation + 1, b"uncertain"),
                        )
                    recovered.verify()

    def test_gc_restarts_safely_after_process_crash(self) -> None:
        self.volume.write(0, b"protected")
        saved = self.volume.snapshot("protected")
        orphan_extent = self.volume._store_extent(b"garbage" + bytes(self.block_size - 7))
        orphan_root = self.volume._root_document({"2": orphan_extent})
        orphan_root_id = self.volume._root_id(orphan_root)
        self.volume._store_root(orphan_root_id, orphan_root)
        self.volume.close()
        self.volume = None

        script = (
            "import os,sys; "
            "from snapcore import SnapCoreVolume; "
            "v=SnapCoreVolume.open(sys.argv[1], "
            "_fault_hook=lambda point: os._exit(95) if point == 'gc_root_unlink' else None); "
            "v.collect_garbage(); os._exit(0)"
        )
        child = subprocess.run(
            [sys.executable, "-c", script, str(self.store)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(child.returncode, 95, child.stderr)

        with SnapCoreVolume.open(self.store) as recovered:
            self.assertEqual(recovered.read(0, 9), b"protected")
            self.assertEqual(recovered.snapshots(verify=True)[0]["root_id"], saved["root_id"])
            self.assertFalse((self.store / "roots" / f"{orphan_root_id}.json").exists())
            self.assertTrue((self.store / "extents" / f"{orphan_extent}.blk").exists())
            collected = recovered.collect_garbage()
            self.assertEqual(collected["removed_extents"], 1)
            protected_extent_id = recovered._load_root(saved["root_id"])["0"]
            self.assertTrue((self.store / "roots" / f"{saved['root_id']}.json").exists())
            self.assertTrue((self.store / "extents" / f"{protected_extent_id}.blk").exists())
            recovered.verify()

    def test_gc_refuses_to_sweep_when_a_live_generation_is_corrupt(self) -> None:
        self.volume.write(0, b"protected")
        live_extent = self.volume._load_root(
            self.volume._generation(self.volume.head_generation)["root_id"]
        )["0"]
        orphan_extent = self.volume._store_extent(b"orphan" + bytes(self.block_size - 6))
        orphan_root = self.volume._root_document({"2": orphan_extent})
        orphan_root_id = self.volume._root_id(orphan_root)
        self.volume._store_root(orphan_root_id, orphan_root)
        self.volume.close()
        (self.store / "extents" / f"{live_extent}.blk").write_bytes(b"corrupt")
        self.volume = None

        with SnapCoreVolume.open(self.store) as reopened:
            with self.assertRaises(IntegrityError):
                reopened.collect_garbage()
            self.assertTrue((self.store / "roots" / f"{orphan_root_id}.json").exists())
            self.assertTrue((self.store / "extents" / f"{orphan_extent}.blk").exists())

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
        run("snapshot", str(store), "discard")
        run("delete-snapshot", str(store), "discard")
        run("rollback", str(store), "before")
        gc = json.loads(run("gc", str(store)).stdout)
        prune = json.loads(run("prune", str(store), "--keep-last", "1").stdout)
        self.assertEqual(run("read", str(store), "0", "3").stdout.strip(), "616263")
        status = json.loads(run("status", str(store), "--verify").stdout)
        self.assertEqual(status["head_generation"], 4)
        self.assertEqual(len(status["snapshots"]), 1)
        self.assertEqual(len(status["generations"]), 2)
        self.assertEqual(gc["removed_extents"], 0)
        self.assertEqual(prune["removed_generations"], 2)

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
