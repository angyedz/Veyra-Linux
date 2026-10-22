#!/usr/bin/env python3
"""Filesystem-neutral Veyra GRUB generation selector (experimental).

A complete selected OS resides in <store>/deployments/<ID>. The selected
kernel and initramfs live under its boot/ directory. The root partition,
whatever supported filesystem it uses, is mounted by Alpine initramfs;
veyra_deployment=<ID> selects that system tree before switch_root.

This prototype uses GRUB's writable environment block for a one-boot trial.
An unconfirmed candidate falls back to the last confirmed deployment on the
following boot. It does NOT sign GRUB/kernel metadata or provide a watchdog.
Never use on production installations before signed boot integration.
"""
import argparse
import fcntl
import json
import os
import posixpath
from pathlib import Path
import re
import shutil
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


def mountinfo_has_mountpoint(path, mountinfo_path="/proc/self/mountinfo"):
    """Check mountinfo directly so same-filesystem bind mounts are detected."""
    escaped = re.compile(r"\\(040|011|012|134)")
    replacements = {"040": " ", "011": "\t", "012": "\n", "134": "\\"}
    target = posixpath.normpath(os.fspath(path))
    try:
        with open(mountinfo_path, encoding="utf-8") as mountinfo:
            for line in mountinfo:
                fields = line.split()
                if len(fields) < 6:
                    continue
                mountpoint = escaped.sub(lambda match: replacements[match.group(1)], fields[4])
                if mountpoint == target:
                    return True
    except OSError as error:
        raise VeyraError("cannot verify deployment store mountpoint") from error
    return False


def require_safe_path(path):
    if not path.is_absolute() or path == Path("/"):
        raise VeyraError("store must be an absolute dedicated mountpoint, never /")
    for part in (path, *path.parents):
        if part == Path("/"):
            break
        if part.is_symlink():
            raise VeyraError(f"symlink in store path: {part}")
    if not path.is_dir() or not mountinfo_has_mountpoint(path):
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
        "insmod loadenv",
        "if [ -s $prefix/grubenv ]; then",
        "    load_env",
        "fi",
        'if [ "${saved_entry}" ]; then',
        '    set default="${saved_entry}"',
        "fi",
        'if [ "${next_entry}" ]; then',
        '    set default="${next_entry}"',
        "    set next_entry=",
        "    save_env next_entry",
        "fi",
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


def grubenv_path(store):
    path = store / "boot" / "grub" / "grubenv"
    safe_file(path)
    return path


def grubenv_run(store, *arguments):
    binary = shutil.which("grub-editenv")
    if not binary:
        raise VeyraError("grub-editenv is required to manage trial boots")
    result = subprocess.run([binary, str(grubenv_path(store)), *arguments],
                            text=True, capture_output=True)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise VeyraError(f"grub-editenv {arguments[0]} failed: {detail}")
    return result.stdout


def grubenv_values(store):
    values = {}
    for line in grubenv_run(store, "list").splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key] = value
    return values


def deployment_from_entry(value, label):
    if not value.startswith("veyra-"):
        raise VeyraError(f"invalid {label} in GRUB environment block")
    return validate_id(value.removeprefix("veyra-"))


def running_deployment():
    try:
        tokens = Path("/proc/cmdline").read_text().split()
    except OSError as error:
        raise VeyraError("cannot read the running kernel command line") from error
    values = [token.partition("=")[2] for token in tokens
              if token.startswith("veyra_deployment=")]
    if len(values) != 1:
        raise VeyraError("running kernel has no unique Veyra deployment ID")
    return validate_id(values[0])


def write_config(store, config, default):
    recovery = ((store / "boot" / "vmlinuz-lts").is_file() and
                (store / "boot" / "initramfs-lts").is_file())
    atomic_write(store / "boot" / "grub" / "grub.cfg",
                 grub_text(config, default, slots(store), recovery))


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
    selection = sub.add_parser("activate", help="arm a one-boot trial after verifying target root")
    selection.add_argument("id")
    rollback = sub.add_parser("rollback", help="select a known-good generation explicitly")
    rollback.add_argument("id")
    confirm = sub.add_parser("confirm", help="confirm the deployment that completed startup")
    confirm.add_argument("id")
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
            grubenv_path(store)
            atomic_write(config_path, json.dumps(config, sort_keys=True) + "\n")
            write_config(store, config, args.default)
        else:
            config = read_config(store)
            if args.action == "status":
                values = grubenv_values(store)
                confirmed_entry = values.get("saved_entry", "")
                trial_entry = values.get("next_entry", "")
                confirmed = deployment_from_entry(confirmed_entry, "confirmed deployment") if confirmed_entry else ""
                trial = deployment_from_entry(trial_entry, "trial deployment") if trial_entry else ""
                print(f"Veyra confirmed={confirmed or selected(store)}"
                      f" trial={trial or 'none'} filesystem={config['fstype']}"
                      f" uuid={config['uuid']} generations={','.join(slots(store))}")
                return
            verify_slot(store, args.id)
            if args.action == "activate":
                values = grubenv_values(store)
                confirmed_entry = values.get("saved_entry", "")
                trial_entry = values.get("next_entry", "")
                if not confirmed_entry:
                    raise VeyraError("no confirmed deployment; refusing to arm a trial")
                confirmed = deployment_from_entry(confirmed_entry, "confirmed deployment")
                verify_slot(store, confirmed)
                if trial_entry:
                    raise VeyraError("a trial is already armed; boot or roll it back first")
                grubenv_run(store, "set", f"next_entry=veyra-{args.id}")
                print(f"Veyra trial armed: {args.id} (one next boot)")
            elif args.action == "confirm":
                if running_deployment() != args.id:
                    raise VeyraError("can only confirm the deployment running this system")
                grubenv_run(store, "set", f"saved_entry=veyra-{args.id}")
                grubenv_run(store, "unset", "next_entry")
                write_config(store, config, args.id)
                print(f"Veyra deployment confirmed: {args.id}")
            elif args.action == "rollback":
                grubenv_run(store, "set", f"saved_entry=veyra-{args.id}")
                grubenv_run(store, "unset", "next_entry")
                write_config(store, config, args.id)
                print(f"Veyra rollback selected: {args.id} (next boot)")


if __name__ == "__main__":
    try:
        main()
    except (VeyraError, OSError, json.JSONDecodeError) as error:
        print(f"veyra-bootctl: {error}", file=sys.stderr)
        sys.exit(1)
