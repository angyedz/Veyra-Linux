#!/usr/bin/env python3
"""Offline, non-root regression for immutable Recovery artifact staging."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / "scripts" / "veyra-recovery-publish.py"
spec = importlib.util.spec_from_file_location("veyra_recovery_publish", source)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def main():
    with tempfile.TemporaryDirectory(prefix="veyra-recovery-publish-") as temp:
        root = Path(temp)
        boot = root / "boot"
        boot.mkdir()
        kernel = root / "test-vmlinuz"
        initramfs = root / "test-initramfs"
        kernel.write_bytes(b"linux kernel")
        initramfs.write_bytes(b"busybox initramfs")
        published = mod.publish(boot, "recovery-v1", kernel, initramfs)
        assert published == boot / "veyra-recovery/recovery-v1"
        metadata = json.loads((published / "manifest.json").read_text())
        assert metadata["id"] == "recovery-v1"
        assert metadata["authentication"] == "unsigned-experimental"
        for name, content in (
            ("vmlinuz", kernel.read_bytes()),
            ("initramfs", initramfs.read_bytes()),
            ("veyra-logo.svg", (ROOT / "branding/veyra-logo.svg").read_bytes()),
        ):
            assert (published / name).read_bytes() == content
            assert metadata["sha256"][name] == hashlib.sha256(content).hexdigest()
        try:
            mod.publish(boot, "recovery-v1", kernel, initramfs)
        except mod.RecoveryError:
            pass
        else:
            raise AssertionError("overwrote immutable recovery deployment")
        for identifier in ("../escape", "x..y", ".hidden", ""):
            try:
                mod.publish(boot, identifier, kernel, initramfs)
            except mod.RecoveryError:
                pass
            else:
                raise AssertionError(f"unsafe recovery identifier accepted: {identifier!r}")
        link = root / "linked-kernel"
        link.symlink_to(kernel)
        try:
            mod.publish(boot, "recovery-invalid", link, initramfs)
        except mod.RecoveryError:
            pass
        else:
            raise AssertionError("accepted symlinked kernel image")
    print("Immutable Recovery artifact staging tests passed")


if __name__ == "__main__":
    main()
