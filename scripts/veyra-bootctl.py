#!/usr/bin/env python3
"""Filesystem-neutral Veyra GRUB generation selector (experimental).

A complete selected OS resides in <store>/deployments/<ID>. The selected
kernel and initramfs live under its boot/ directory. The root partition,
whatever supported filesystem it uses, is mounted by Alpine initramfs;
veyra_deployment=<ID> selects that system tree before switch_root.

This implementation does NOT sign GRUB/kernel metadata or offer automatic
watchdog rollback. A bootable previous entry remains visible at all times.
Never use on production installations before signed boot integration.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
UUID = re.compile(r"^[0-9a-fA-F-]{4,64}$")
FILESYSTEMS = {"ext4": "ext2", "xfs": "xfs", "f2fs": "f2fs", "btrfs": "btrfs"}
MARKER = "VEYRA-DEPLOYMENT-STORE-v2"
VERSION = 1


class VeyraError(Exception):
    pass


def require_safe_path(path):
    if not path.is_absolute() or path == Path("/"):
        raise VeyraError("store must be an absolute dedicated mountpoint, never /")
    for part in (path, *path.parents):
        if part == Path("/"):
            break
        if part.is_symlink():
            raise VeyraError(f"symlink in store path: {part}")
    if not path.is_dir() or not os.path.ismount(path):
        raise VeyraError("store must be an independently mounted directory")
    if (path / ".veyra-deployment-store").is_symlink():
        raise VeyraError("symlinked deployment marker")
    try:
        marker = (path / ".veyra-deployment-store").read_text().strip()
    except OSError as error:
        raise VeyraError("deployment store not initialized") from error
    if marker != MARKER:
        raise VeyraError("unsupported deployment store marker")


def safe_dir(directory):
    if directory.is_symlink() or not directory.is_dir():
        raise VeyraError(f"invalid or symlinked directory: {directory}")


def safe_file(filename):
    if filename.is_symlink() or not filename.is_file():
        raise VeyraError(f"invalid or symlinked file: {filename}")


def validate_id(identifier):
    if not ID.fullmatch(identifier) or identifier in {".", ".."} or ".." in identifier:
        raise VeyraError(f"invalid Veyra deployment ID: {identifier!r}")
    return identifier


def verify_slot(store, identifier):
    validate_id(identifier)
    safe_dir(store / "deployments")
    root = store / "deployments" / identifier
    safe_dir(root)
    for name in ("etc", "etc/apk", "etc/veyra", "boot"):
        safe_dir(root / name)
    for name in ("etc/apk/world", "etc/veyra/deployment-id",
                 "boot/vmlinuz-lts", "boot/initramfs-lts"):
        safe_file(root / name)
    if (root / "etc/veyra/deployment-id").read_text().strip() != identifier:
        raise VeyraError(f"deployment ID mismatch: {identifier}")
    if (root / "boot/vmlinuz-lts").stat().st_size == 0 or (
            root / "boot/initramfs-lts").stat().st_size == 0:
        raise VeyraError("empty kernel/initramfs image")
    if not (root / "etc/apk/world").read_text().strip():
        raise VeyraError("empty APK package world")
    return root


def slots(store):
    directory = store / "deployments"
    safe_dir(directory)
    entries = []
    for candidate in sorted(directory.iterdir()):
        if candidate.name.startswith("."):
            continue
        if ID.fullmatch(candidate.name):
            try:
                verify_slot(store, candidate.name)
            except VeyraError:
                continue  # inactive, partial or not yet kernel-bootable
            entries.append(candidate.name)
    if not entries:
        raise VeyraError("no bootable Veyra deployments")
    return entries


def atomic_write(path, data):
    safe_dir(path.parent)
    if path.is_symlink():
        raise VeyraError(f"refusing symlinked output: {path}")
    fd, tmp = tempfile.mkstemp(prefix=".veyra-write-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
            os.fchmod(file.fileno(), 0o644)
        os.replace(tmp, path)
        directory_fd = os.open(path.parent, os.O_DIRECTORY | os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_config(store):
    path = store / "boot-state" / "config.json"
    safe_file(path)
    data = json.loads(path.read_text())
    if data.get("format") != VERSION:
        raise VeyraError("unsupported boot state format")
    if not UUID.fullmatch(data.get("uuid", "")):
        raise VeyraError("invalid root filesystem UUID")
    if data.get("fstype") not in FILESYSTEMS:
        raise VeyraError("unsupported root filesystem")
    return data


def grub_text(config, default, candidates):
    # All interpolated fields are strictly allowlisted before rendering.
    validate_id(default)
    if default not in candidates:
        raise VeyraError("selected boot deployment is not bootable")
    uuid = config["uuid"]
    fstype = config["fstype"]
    module = FILESYSTEMS[fstype]
    lines = [
        "# Generated by Veyra bootctl. Manual edits are overwritten.",
        f"# VEYRA_DEFAULT={default}",
        f"set default='veyra-{default}'",
        "set timeout=5",
        "set timeout_style=menu",
        "insmod part_gpt",
        "insmod part_msdos",
        "insmod search_fs_uuid",
        f"insmod {module}",
        "",
    ]
    for identifier in candidates:
        lines.extend([
            f"menuentry 'Veyra Linux ({identifier})' --id='veyra-{identifier}' {{",
            f"    search --no-floppy --fs-uuid --set=root {uuid}",
            f"    linux /deployments/{identifier}/boot/vmlinuz-lts root=UUID={uuid} "
            f"rootfstype={fstype} rootflags=rw veyra_deployment={identifier}",
            f"    initrd /deployments/{identifier}/boot/initramfs-lts",
            "}",
            "",
        ])
    return "\n".join(lines)


def selected(store):
    path = store / "boot" / "grub" / "grub.cfg"
    safe_file(path)
    header = path.read_text().splitlines()[:5]
    matches = [line.partition("=")[2] for line in header
               if line.startswith("# VEYRA_DEFAULT=")]
    if len(matches) != 1:
        raise VeyraError("unrecognized GRUB selection marker")
    return validate_id(matches[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", type=Path, required=True)
    sub = parser.add_subparsers(dest="action", required=True)
    init = sub.add_parser("init", help="create boot metadata and config from an existing deployment")
    init.add_argument("--uuid", required=True)
    init.add_argument("--fstype", choices=sorted(FILESYSTEMS), required=True)
    init.add_argument("--default", required=True)
    selection = sub.add_parser("activate", help="atomically replace GRUB default after verifying target root")
    selection.add_argument("id")
    rollback = sub.add_parser("rollback", help="select a known-good generation explicitly")
    rollback.add_argument("id")
    sub.add_parser("status")
    args = parser.parse_args()

    store = args.store
    require_safe_path(store)
    state = store / "boot-state"
    safe_dir(state)
    grub = store / "boot" / "grub"
    safe_dir(grub)
    lock_path = state / ".bootctl-lock"
    if lock_path.is_symlink():
        raise VeyraError("boot state lock is a symlink")
    with open(lock_path, "a+", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == "init":
            if args.fstype not in FILESYSTEMS or not UUID.fullmatch(args.uuid):
                raise VeyraError("invalid root UUID or filesystem")
            verify_slot(store, args.default)
            config_path = state / "config.json"
            if config_path.exists() or config_path.is_symlink():
                raise VeyraError("boot state already initialized")
            if (grub / "grub.cfg").exists() or (grub / "grub.cfg").is_symlink():
                raise VeyraError("existing GRUB config; refusing to replace unowned boot")
            config = {"format": VERSION, "uuid": args.uuid, "fstype": args.fstype}
            atomic_write(config_path, json.dumps(config, sort_keys=True) + "\n")
            atomic_write(grub / "grub.cfg", grub_text(config, args.default, slots(store)))
        else:
            config = read_config(store)
            if args.action == "status":
                print(f"Veyra selected={selected(store)} filesystem={config['fstype']}"
                      f" uuid={config['uuid']} generations={','.join(slots(store))}")
                return
            verify_slot(store, args.id)
            # Replace only the small bootloader config; never rewrite a running root.
            atomic_write(grub / "grub.cfg", grub_text(config, args.id, slots(store)))
        print(f"Veyra {args.action}: boot selection={selected(store)} (next boot)")


if __name__ == "__main__":
    try:
        main()
    except (VeyraError, OSError, json.JSONDecodeError) as error:
        print(f"veyra-bootctl: {error}", file=sys.stderr)
        sys.exit(1)
