#!/usr/bin/env python3
"""Filesystem-neutral Veyra GRUB generation selector (experimental).

A complete selected OS resides in <store>/deployments/<ID>. The selected
kernel and initramfs live under its boot/ directory. The root partition,
whatever supported filesystem it uses, is mounted by Alpine initramfs;
veyra_deployment=<ID> selects that system tree before switch_root.

This implementation does NOT sign GRUB/kernel metadata. Before booting a
candidate, the initramfs arms a previous-known-good GRUB fallback for the
next reboot; OpenRC confirms the candidate after startup. Failure before the
initramfs reaches the fallback hook still needs manual GRUB recovery.
Never use on production installations before signed boot integration.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import tempfile

ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
UUID = re.compile(r"^[0-9a-fA-F-]{4,64}$")
FILESYSTEMS = {"ext4": "ext2", "xfs": "xfs", "f2fs": "f2fs", "btrfs": "btrfs"}
MARKER = "VEYRA-DEPLOYMENT-STORE-v2"
VERSION = 1


class VeyraError(Exception):
    pass


def _mountinfo_unescape(field):
    return re.sub(
        r"\\([0-7]{3})",
        lambda match: chr(int(match.group(1), 8)),
        field,
    )


def _is_mountpoint(path):
    """Detect ordinary and bind mounts from this process's mount namespace."""
    target = os.path.normpath(str(path))
    try:
        with open("/proc/self/mountinfo", encoding="utf-8") as mountinfo:
            for line in mountinfo:
                fields = line.split()
                if len(fields) >= 6 and os.path.normpath(
                    _mountinfo_unescape(fields[4])
                ) == target:
                    return True
    except OSError:
        return False
    return False


def require_safe_path(path):
    if not path.is_absolute() or path == Path("/"):
        raise VeyraError("store must be an absolute dedicated mountpoint, never /")
    for part in (path, *path.parents):
        if part == Path("/"):
            break
        if part.is_symlink():
            raise VeyraError(f"symlink in store path: {part}")
    if not path.is_dir() or not _is_mountpoint(path):
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


def grub_text(config, default, candidates, recovery=False):
    # All interpolated fields are strictly allowlisted before rendering.
    validate_id(default)
    if default not in candidates:
        raise VeyraError("selected boot deployment is not bootable")
    uuid = config["uuid"]
    fstype = config["fstype"]
    module = FILESYSTEMS[fstype]
    serial = " console=tty0 console=ttyS0,115200" if config.get("serial_console", False) else ""
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
            f"rootfstype={fstype} rootflags=rw veyra_deployment={identifier}{serial}",
            f"    initrd /deployments/{identifier}/boot/initramfs-lts",
            "}",
            "",
        ])
    if recovery:
        lines.extend([
            "menuentry 'Veyra conventional recovery (original Alpine root)' --id=veyra-legacy {",
            f"    search --no-floppy --fs-uuid --set=root {uuid}",
            f"    linux /boot/vmlinuz-lts root=UUID={uuid} rootfstype={fstype} rootflags=rw{serial}",
            "    initrd /boot/initramfs-lts",
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


def pending_state(store):
    path = store / "boot-state" / "pending"
    if not path.exists() and not path.is_symlink():
        return None
    safe_file(path)
    words = path.read_text().strip().split()
    if len(words) != 2:
        raise VeyraError("invalid A/B boot pending metadata")
    return (validate_id(words[0]), validate_id(words[1]))


def live_deployment():
    try:
        tokens = Path("/proc/cmdline").read_text().split()
    except OSError as error:
        raise VeyraError("cannot read currently booted deployment") from error
    ids = [token.partition("=")[2] for token in tokens
           if token.startswith("veyra_deployment=")]
    if len(ids) != 1:
        raise VeyraError("current kernel was not booted with Veyra deployment selection")
    return validate_id(ids[0])


def durable_remove(path):
    if path.is_symlink():
        raise VeyraError(f"symlinked pending marker: {path}")
    if path.exists():
        path.unlink()
        dirfd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dirfd)
        finally:
            os.close(dirfd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", type=Path, required=True)
    sub = parser.add_subparsers(dest="action", required=True)
    init = sub.add_parser("init", help="create boot metadata and config from an existing deployment")
    init.add_argument("--uuid", required=True)
    init.add_argument("--fstype", choices=sorted(FILESYSTEMS), required=True)
    init.add_argument("--default", required=True)
    init.add_argument("--serial-console", action="store_true",
                      help="add ttyS0 console for disposable QEMU debugging")
    init.add_argument("--adopt-legacy-grub", action="store_true",
                      help="back up and replace conventional GRUB config")
    selection = sub.add_parser("activate", help="atomically replace GRUB default after verifying target root")
    selection.add_argument("id")
    rollback = sub.add_parser("rollback", help="select a known-good generation explicitly")
    rollback.add_argument("id")
    sub.add_parser("status")
    confirm = sub.add_parser("confirm", help="acknowledge a candidate after successful OpenRC boot")
    confirm.add_argument("--booted-id", help="CI-only override; requires root")
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
            existing = grub / "grub.cfg"
            if existing.exists() or existing.is_symlink():
                if not args.adopt_legacy_grub:
                    raise VeyraError("existing GRUB config; --adopt-legacy-grub required")
                safe_file(existing)
                safe_file(store / "boot" / "vmlinuz-lts")
                safe_file(store / "boot" / "initramfs-lts")
                atomic_write(state / "legacy-grub.cfg", existing.read_text())
            config = {"format": VERSION, "uuid": args.uuid, "fstype": args.fstype,
                      "serial_console": bool(args.serial_console)}
            atomic_write(config_path, json.dumps(config, sort_keys=True) + "\n")
            recovery = (store / "boot" / "vmlinuz-lts").is_file() and (store / "boot" / "initramfs-lts").is_file()
            atomic_write(grub / "grub.cfg", grub_text(config, args.default, slots(store), recovery))
        else:
            config = read_config(store)
            pending = pending_state(store)
            if args.action == "status":
                suffix = f" pending={pending[0]} fallback={pending[1]}" if pending else ""
                print(f"Veyra selected={selected(store)} filesystem={config['fstype']}"
                      f" uuid={config['uuid']} generations={','.join(slots(store))}{suffix}")
                return
            recovery = (store / "boot" / "vmlinuz-lts").is_file() and (store / "boot" / "initramfs-lts").is_file()
            if args.action == "confirm":
                if not pending:
                    print("Veyra boot confirmed (no pending update)")
                    return
                if os.geteuid() != 0:
                    raise VeyraError("boot confirmation requires root")
                booted = validate_id(args.booted_id) if args.booted_id else live_deployment()
                if booted != pending[0]:
                    raise VeyraError(f"booted {booted}, pending candidate {pending[0]}")
                verify_slot(store, booted)
                atomic_write(grub / "grub.cfg",
                             grub_text(config, booted, slots(store), recovery))
                durable_remove(state / "pending")
                print(f"Veyra confirmed boot: {booted}")
                return
            verify_slot(store, args.id)
            if args.action == "activate":
                if pending:
                    raise VeyraError("candidate already pending; confirm or rollback first")
                fallback = selected(store)
                if args.id == fallback:
                    print(f"Veyra already selected: {fallback}")
                    return
                verify_slot(store, fallback)
                # Durable fallback and pending intent PRECEDE the boot switch.
                atomic_write(state / "fallback-grub.cfg",
                             grub_text(config, fallback, slots(store), recovery))
                atomic_write(state / "pending", f"{args.id} {fallback}\n")
                atomic_write(grub / "grub.cfg",
                             grub_text(config, args.id, slots(store), recovery))
            elif args.action == "rollback":
                # Explicit rollback selects a known-good root and cancels the
                # candidate transaction in a repeatable order.
                atomic_write(grub / "grub.cfg",
                             grub_text(config, args.id, slots(store), recovery))
                durable_remove(state / "pending")
            else:
                raise VeyraError("unsupported boot operation")
        print(f"Veyra {args.action}: boot selection={selected(store)} (next boot)")


if __name__ == "__main__":
    try:
        main()
    except (VeyraError, OSError, json.JSONDecodeError) as error:
        print(f"veyra-bootctl: {error}", file=sys.stderr)
        sys.exit(1)
