#!/usr/bin/env python3
"""Non-destructive GRUB A/B policy checks without touching host boot state."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "scripts" / "veyra-bootctl.py"
spec = importlib.util.spec_from_file_location("veyra_bootctl", MODULE)
bootctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootctl)


def fake_slot(store, identifier):
    root = store / "deployments" / identifier
    for directory in ("etc/apk", "etc/veyra", "boot", "var/lib/veyra/user-root"):
        (root / directory).mkdir(parents=True, exist_ok=True)
    (root / "etc/apk/world").write_text("alpine-base\n")
    (root / "etc/veyra/deployment-id").write_text(identifier + "\n")
    (root / "boot/vmlinuz-lts").write_bytes(b"kernel")
    (root / "boot/initramfs-lts").write_bytes(b"initramfs")


def fake_user_environment(store, identifier):
    root = store / "user-environments" / identifier
    for directory in ("etc/apk", "etc/veyra", "sbin"):
        (root / directory).mkdir(parents=True, exist_ok=True)
    (root / "etc/apk/world").write_text("alpine-base\n")
    (root / "etc/veyra/user-environment-id").write_text(identifier + "\n")
    init = root / "sbin/init"
    init.write_text("#!/bin/sh\nexit 0\n")
    init.chmod(0o755)


def test_activate_publishes_candidate_before_arming(store):
    (store / "boot-state").mkdir()
    (store / "boot/grub").mkdir(parents=True)
    (store / "boot/grub/grubenv").write_text("fake grub environment\n")
    (store / "boot-state/config.json").write_text(json.dumps({
        "format": bootctl.VERSION,
        "uuid": "aabb1122-3344",
        "fstype": "ext4",
        "serial_console": True,
    }))
    fake_slot(store, "A")
    fake_slot(store, "B")
    fake_user_environment(store, "U-A")
    fake_user_environment(store, "U-B")
    (store / "deployments/A/etc/veyra/user-environment-id").write_text("U-A\n")
    (store / "deployments/B/etc/veyra/user-environment-id").write_text("U-B\n")
    (store / "boot/grub/grub.cfg").write_text(
        bootctl.grub_text(
            {"uuid": "aabb1122-3344", "fstype": "ext4",
             "serial_console": True}, "A", ["A"], True))
    grubenv = {"saved_entry": "veyra-A"}
    operations = []

    def fake_grubenv_run(_store, *arguments):
        operations.append(arguments)
        if arguments == ("list",):
            return "".join(f"{key}={value}\n" for key, value in grubenv.items())
        if arguments[0] == "set":
            key, value = arguments[1].split("=", 1)
            grubenv[key] = value
            return ""
        if arguments[0] == "unset":
            grubenv.pop(arguments[1], None)
            return ""
        raise AssertionError(f"unexpected grub-editenv arguments: {arguments!r}")

    with patch.object(bootctl, "require_safe_path"), \
         patch.object(bootctl, "grubenv_run", side_effect=fake_grubenv_run), \
         patch.object(sys, "argv", ["veyra-bootctl", "--store", str(store),
                                     "activate", "B"]):
        bootctl.main()

    generated = (store / "boot/grub/grub.cfg").read_text()
    assert "veyra_deployment=B" in generated
    assert "veyra_user_environment=U-A" in generated
    assert "veyra_user_environment=U-B" in generated
    assert "# VEYRA_DEFAULT=A" in generated
    assert grubenv["saved_entry"] == "veyra-A"
    assert grubenv["next_entry"] == "veyra-B"
    assert operations[-1] == ("set", "next_entry=veyra-B")


def test_running_pair_requires_the_selected_mounted_user_root(store):
    fake_slot(store, "A")
    fake_user_environment(store, "U-A")
    (store / "deployments/A/etc/veyra/user-environment-id").write_text("U-A\n")
    runtime = store / "mounted-user-root"
    (runtime / "etc/veyra").mkdir(parents=True)
    (runtime / "etc/veyra/user-environment-id").write_text("U-A\n")

    with patch.object(bootctl, "mountinfo_has_mountpoint", return_value=True):
        bootctl.verify_running_pair(store, "A", "U-A", runtime)
        (runtime / "etc/veyra/user-environment-id").write_text("U-OLD\n")
        try:
            bootctl.verify_running_pair(store, "A", "U-A", runtime)
        except bootctl.VeyraError:
            pass
        else:
            raise AssertionError("mismatched mounted user environment was accepted")
        (runtime / "etc/veyra/user-environment-id").write_text("U-A\n")
        with patch.object(bootctl, "mountinfo_has_mountpoint", return_value=False):
            try:
                bootctl.verify_running_pair(store, "A", "U-A", runtime)
            except bootctl.VeyraError:
                pass
            else:
                raise AssertionError("unmounted user environment was accepted")


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

        fake_user_environment(store, "U-A")
        (store / "deployments/A/etc/veyra/user-environment-id").write_text("U-A\n")
        paired = bootctl.grub_text(
            config, "A", ["A", "B"],
            user_environments={"A": "U-A"})
        assert "veyra_deployment=A" in paired
        assert "veyra_user_environment=U-A" in paired
        assert "veyra_user_environment=" not in paired.split("veyra_deployment=B", 1)[1]

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

    with tempfile.TemporaryDirectory(prefix="veyra-bootctl-activate-") as tmp:
        test_activate_publishes_candidate_before_arming(Path(tmp))
    with tempfile.TemporaryDirectory(prefix="veyra-bootctl-pair-") as tmp:
        test_running_pair_requires_the_selected_mounted_user_root(Path(tmp))
    print("Veyra GRUB generation policy checks passed")


if __name__ == "__main__":
    main()
