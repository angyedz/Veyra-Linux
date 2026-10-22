#!/usr/bin/env python3
"""Non-destructive GRUB A/B policy checks without touching host boot state."""
import importlib.util
from pathlib import Path
import tempfile

MODULE = Path(__file__).resolve().parents[1] / "scripts" / "veyra-bootctl.py"
spec = importlib.util.spec_from_file_location("veyra_bootctl", MODULE)
bootctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootctl)


def fake_slot(store, identifier):
    root = store / "deployments" / identifier
    for directory in ("etc/apk", "etc/veyra", "boot"):
        (root / directory).mkdir(parents=True, exist_ok=True)
    (root / "etc/apk/world").write_text("alpine-base\n")
    (root / "etc/veyra/deployment-id").write_text(identifier + "\n")
    (root / "boot/vmlinuz-lts").write_bytes(b"kernel")
    (root / "boot/initramfs-lts").write_bytes(b"initramfs")


def main():
    with tempfile.TemporaryDirectory(prefix="veyra-mountinfo-policy-") as tmp:
        mountinfo = Path(tmp) / "mountinfo"
        mountinfo.write_text(
            "36 25 8:1 / /var/lib/veyra/store rw,relatime - ext4 /dev/vda1 rw\n"
            "37 25 8:1 / /mnt/veyra\\040store rw,relatime - ext4 /dev/vda1 rw\n"
        )
        assert bootctl.mountinfo_has_mountpoint("/var/lib/veyra/store", mountinfo)
        assert bootctl.mountinfo_has_mountpoint("/mnt/veyra store", mountinfo)
        assert not bootctl.mountinfo_has_mountpoint("/var/lib/veyra", mountinfo)

    with tempfile.TemporaryDirectory(prefix="veyra-bootctl-policy-") as tmp:
        store = Path(tmp)
        fake_slot(store, "A")
        config = {"uuid": "aabb1122-3344", "fstype": "ext4", "serial_console": True}
        assert bootctl.slots(store) == ["A"]
        initial = bootctl.grub_text(config, "A", bootctl.slots(store), True)
        assert "# VEYRA_DEFAULT=A" in initial
        assert "veyra_deployment=A" in initial
        assert "veyra_deployment=B" not in initial
        assert "insmod loadenv" in initial
        assert "load_env" in initial
        assert "set next_entry=" in initial
        assert "save_env next_entry" in initial
        assert "Veyra conventional recovery" in initial

        # Staging B alone cannot change the *existing* GRUB selection.
        fake_slot(store, "B")
        assert bootctl.slots(store) == ["A", "B"]
        assert "veyra_deployment=B" not in initial
        activated = bootctl.grub_text(config, "A", bootctl.slots(store), True)
        assert "# VEYRA_DEFAULT=A" in activated
        assert "set default='veyra-A'" in activated
        assert 'set default="${saved_entry}"' in activated
        assert 'set default="${next_entry}"' in activated
        assert "veyra_deployment=B" in activated
        assert "veyra_deployment=A" in activated

        for invalid in ("../escape", ".secret", "two/paths", "a..b", ""):
            try:
                bootctl.validate_id(invalid)
            except bootctl.VeyraError:
                pass
            else:
                raise AssertionError(f"unsafe deployment ID accepted: {invalid!r}")
        (store / "boot/grub").mkdir(parents=True)
        (store / "boot/grub/grub.cfg").write_text(activated)
        assert bootctl.selected(store) == "A"
    print("Veyra GRUB generation policy checks passed")


if __name__ == "__main__":
    main()
