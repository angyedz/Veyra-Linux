#!/usr/bin/env python3
"""Developer CLI for the experimental file-backed SnapCore prototype."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from snapcore import SnapCoreError, SnapCoreVolume


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="veyra-snapcore",
        description="Experimental file-backed block CoW volume (not production storage).",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("format", help="create a new empty test volume")
    create.add_argument("store", type=Path)
    create.add_argument("--size-bytes", required=True, type=int)
    create.add_argument("--block-size", default=4096, type=int)

    status = subparsers.add_parser("status", help="show generations and checkpoints")
    status.add_argument("store", type=Path)
    status.add_argument("--verify", action="store_true")

    write = subparsers.add_parser("write", help="write hexadecimal bytes into the head")
    write.add_argument("store", type=Path)
    write.add_argument("offset", type=int)
    write.add_argument("hex_data")

    read = subparsers.add_parser("read", help="read a byte range as hexadecimal")
    read.add_argument("store", type=Path)
    read.add_argument("offset", type=int)
    read.add_argument("length", type=int)

    snapshot = subparsers.add_parser("snapshot", help="retain the current head")
    snapshot.add_argument("store", type=Path)
    snapshot.add_argument("name")

    rollback = subparsers.add_parser("rollback", help="create a new head from a checkpoint")
    rollback.add_argument("store", type=Path)
    rollback.add_argument("name")

    delete_snapshot = subparsers.add_parser(
        "delete-snapshot", help="remove a checkpoint name while retaining generations"
    )
    delete_snapshot.add_argument("store", type=Path)
    delete_snapshot.add_argument("name")

    gc = subparsers.add_parser("gc", help="remove unreferenced immutable objects")
    gc.add_argument("store", type=Path)

    prune = subparsers.add_parser(
        "prune", help="compact old generations while preserving checkpoints"
    )
    prune.add_argument("store", type=Path)
    prune.add_argument("--keep-last", required=True, type=int)

    verify = subparsers.add_parser("verify", help="verify all retained generations")
    verify.add_argument("store", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "format":
            with SnapCoreVolume.format(
                args.store, args.size_bytes, args.block_size
            ) as volume:
                print(
                    json.dumps(
                        {
                            "volume_id": volume.volume_id,
                            "size_bytes": volume.size_bytes,
                            "block_size": volume.block_size,
                            "head_generation": volume.head_generation,
                        },
                        sort_keys=True,
                    )
                )
            return 0

        with SnapCoreVolume.open(args.store) as volume:
            if args.command == "status":
                result = {
                    "volume_id": volume.volume_id,
                    "size_bytes": volume.size_bytes,
                    "block_size": volume.block_size,
                    "head_generation": volume.head_generation,
                    "generations": volume.generations(),
                    "snapshots": volume.snapshots(verify=args.verify),
                }
                print(json.dumps(result, sort_keys=True))
            elif args.command == "write":
                try:
                    payload = bytes.fromhex(args.hex_data)
                except ValueError as exc:
                    raise ValueError("hex_data must contain pairs of hexadecimal digits") from exc
                generation = volume.write(args.offset, payload)
                print(json.dumps({"head_generation": generation}, sort_keys=True))
            elif args.command == "read":
                print(volume.read(args.offset, args.length).hex())
            elif args.command == "snapshot":
                print(json.dumps(volume.snapshot(args.name), sort_keys=True))
            elif args.command == "rollback":
                generation = volume.rollback(args.name)
                print(json.dumps({"head_generation": generation}, sort_keys=True))
            elif args.command == "delete-snapshot":
                volume.delete_snapshot(args.name)
                print(json.dumps({"deleted_snapshot": args.name}, sort_keys=True))
            elif args.command == "gc":
                print(json.dumps(volume.collect_garbage(), sort_keys=True))
            elif args.command == "prune":
                print(json.dumps(
                    volume.prune_generations(args.keep_last), sort_keys=True
                ))
            elif args.command == "verify":
                print(json.dumps(volume.verify(), sort_keys=True))
        return 0
    except (OSError, ValueError, SnapCoreError) as exc:
        parser.exit(2, f"veyra-snapcore: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
