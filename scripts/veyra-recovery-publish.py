#!/usr/bin/env python3
"""Stage an immutable Veyra Recovery kernel/initramfs, without altering GRUB.

EXPERIMENTAL. The manifest has corruption-detection hashes, NOT signatures.
Run only against an intentionally mounted offline Veyra deployment store.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
MARKER = "VEYRA-DEPLOYMENT-STORE-v2"
LOGO = Path(__file__).resolve().parents[1] / "branding" / "veyra-logo.svg"


class RecoveryError(Exception):
    pass


def safe_directory(directory):
    if directory.is_symlink() or not directory.is_dir():
        raise RecoveryError(f"missing or symlinked directory: {directory}")


def validate_store(store):
    if not store.is_absolute() or store == Path("/"):
        raise RecoveryError("store must be an absolute separate mount, not /")
    for parent in (store, *store.parents):
        if parent == Path("/"):
            break
        if parent.is_symlink():
            raise RecoveryError(f"symlinked store path: {parent}")
    safe_directory(store)
    if not os.path.ismount(store):
        raise RecoveryError("store must be an independently mounted filesystem")
    marker = store / ".veyra-deployment-store"
    if marker.is_symlink() or not marker.is_file() or marker.read_text().strip() != MARKER:
        raise RecoveryError("store is not an initialized Veyra deployment store")
    boot = store / "boot"
    safe_directory(boot)
    if boot.stat().st_dev != store.stat().st_dev:
        raise RecoveryError("separately mounted /boot is not yet supported")
    return boot


def copy_hashed(source, target):
    if source.is_symlink() or not source.is_file() or source.stat().st_size == 0:
        raise RecoveryError(f"invalid source artifact: {source}")
    digest = hashlib.sha256()
    with source.open("rb") as reader, target.open("xb") as writer:
        while True:
            data = reader.read(1024 * 1024)
            if not data:
                break
            writer.write(data)
            digest.update(data)
        writer.flush()
        os.fchmod(writer.fileno(), 0o644)
        os.fsync(writer.fileno())
    return digest.hexdigest()


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def publish(boot, identifier, kernel, initramfs, logo=LOGO):
    if not ID.fullmatch(identifier) or ".." in identifier:
        raise RecoveryError("unsafe recovery image identifier")
    # Validate all sources before allocating any temporary generation.
    # copy_hashed performs the same checks again at the point of use.
    for source in (kernel, initramfs, logo):
        if source.is_symlink() or not source.is_file() or source.stat().st_size == 0:
            raise RecoveryError(f"invalid source artifact: {source}")
    safe_directory(boot)
    container = boot / "veyra-recovery"
    if not container.exists():
        container.mkdir(mode=0o755)
        sync_directory(boot)
    safe_directory(container)
    if container.stat().st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RecoveryError("recovery image directory is writable by untrusted users")
    target = container / identifier
    lock_path = container / ".publish-lock"
    if lock_path.is_symlink():
        raise RecoveryError("symlinked publish lock")
    with lock_path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if target.exists() or target.is_symlink():
            raise RecoveryError("recovery image identifier already exists")
        temp = Path(tempfile.mkdtemp(prefix=".staging-", dir=container))
        try:
            hashes = {
                "vmlinuz": copy_hashed(kernel, temp / "vmlinuz"),
                "initramfs": copy_hashed(initramfs, temp / "initramfs"),
                "veyra-logo.svg": copy_hashed(logo, temp / "veyra-logo.svg"),
            }
            manifest = {
                "format": 1, "id": identifier,
                "sha256": hashes,
                "authentication": "unsigned-experimental",
            }
            with (temp / "manifest.json").open("x") as writer:
                json.dump(manifest, writer, sort_keys=True)
                writer.write("\n")
                writer.flush()
                os.fchmod(writer.fileno(), 0o644)
                os.fsync(writer.fileno())
            sync_directory(temp)
            os.rename(temp, target)
            sync_directory(container)
        finally:
            if temp.exists():
                # Never recursively remove a potentially untrusted recovery
                # directory; incomplete unpublished files require inspection.
                print(f"Unpublished recovery staging remains: {temp}", file=sys.stderr)
        return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", type=Path, required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--initramfs", type=Path, required=True)
    args = parser.parse_args()
    try:
        boot = validate_store(args.store)
        published = publish(boot, args.id, args.kernel, args.initramfs)
    except (RecoveryError, OSError) as error:
        parser.error(str(error))
    print(f"Published immutable recovery artifacts: {published}")
    print("GRUB is unchanged. Images are not signed and must not be trusted for production.")


if __name__ == "__main__":
    main()
