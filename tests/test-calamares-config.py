#!/usr/bin/env python3
"""Validate Veyra's Calamares integration before risking a real disk."""
import ast
import re
from pathlib import Path
import yaml

root = Path(__file__).resolve().parents[1]
configs = [root / "calamares/settings.conf"]
configs.extend(sorted((root / "calamares/modules").glob("*.conf")))
configs.append(root / "calamares/branding/veyra/branding.desc")
for file in configs:
    with file.open(encoding="utf-8") as handle:
        data = yaml.safe_load(handle)
    assert isinstance(data, dict), file
    print(f"Parsed {file.relative_to(root)}")

with (root / "calamares/settings.conf").open(encoding="utf-8") as stream:
    settings = yaml.safe_load(stream)
assert settings["branding"] == "veyra"
with (root / "calamares/branding/veyra/branding.desc").open(encoding="utf-8") as stream:
    branding = yaml.safe_load(stream)
assert branding["slideshow"] == "show.qml"
assert branding["slideshowAPI"] == 2
assert (root / "calamares/branding/veyra/show.qml").is_file()
assert (root / "calamares/branding/veyra" / branding["images"]["productLogo"]).is_file()
instances = {instance["id"]: instance for instance in settings["instances"]}
assert "desktop" not in instances

# Keep the real-disk QEMU install runner selectable for every Calamares option.
qemu_source = (root / "tests/test-installed-qemu.py").read_text(encoding="utf-8")
qemu_tree = ast.parse(qemu_source)
desktop_argument = next(
    node for node in ast.walk(qemu_tree)
    if isinstance(node, ast.Call)
    and isinstance(node.func, ast.Attribute)
    and node.func.attr == "add_argument"
    and node.args
    and isinstance(node.args[0], ast.Constant)
    and node.args[0].value == "--desktop"
)
desktop_choices = next(
    ast.literal_eval(keyword.value)
    for keyword in desktop_argument.keywords
    if keyword.arg == "choices"
)
assert desktop_choices == ["plasma", "gnome", "xfce", "lxqt", "minimal"]
workflow = yaml.safe_load((root / ".github/workflows/iso.yml").read_text(encoding="utf-8"))
install_matrix = workflow["jobs"]["install-e2e"]["strategy"]["matrix"]
assert install_matrix["desktop"] == desktop_choices
assert install_matrix["firmware"] == ["bios"]
assert {(item["desktop"], item["firmware"]) for item in install_matrix["include"]} == {
    ("plasma", "uefi"), ("minimal", "uefi")
}
firmware_argument = next(
    node for node in ast.walk(qemu_tree)
    if isinstance(node, ast.Call)
    and isinstance(node.func, ast.Attribute)
    and node.func.attr == "add_argument"
    and node.args
    and isinstance(node.args[0], ast.Constant)
    and node.args[0].value == "--firmware"
)
firmware_choices = next(
    ast.literal_eval(keyword.value)
    for keyword in firmware_argument.keywords
    if keyword.arg == "choices"
)
assert firmware_choices == ["bios", "uefi"]

with (root / "calamares/modules/services-openrc.conf").open(encoding="utf-8") as stream:
    openrc = yaml.safe_load(stream)
service_entries = {entry["name"]: entry for entry in openrc["services"]}
for name in ("dbus", "elogind", "networkmanager"):
    assert service_entries[name]["mandatory"] is True
assert "nix-daemon" in service_entries
service_loops = re.findall(r"for service in ([a-z0-9 -]+); do", qemu_source)
assert set(service_entries) in [set(loop.split()) for loop in service_loops]
assert r"[A-Za-z0-9_.()-]+ )?login:" in qemu_source

seq = settings["sequence"]
assert any("show" in step for step in seq)
show_modules = next(step["show"] for step in seq if "show" in step)
assert "packagechooser@desktop" not in show_modules
exec_modules = next(step["exec"] for step in seq if "exec" in step)
for name in ("partition", "mount", "shellprocess@copy", "shellprocess@prepare",
             "shellprocess@desktop-install", "shellprocess@hardware",
             "users", "services-openrc", "bootloader", "umount"):
    assert name in exec_modules, name
assert exec_modules.index("partition") < exec_modules.index("mount")
assert exec_modules.index("mount") < exec_modules.index("shellprocess@copy")
assert exec_modules.index("shellprocess@copy") < exec_modules.index("users")
assert exec_modules.index("shellprocess@prepare") < exec_modules.index("shellprocess@desktop-install")
assert exec_modules.index("shellprocess@desktop-install") < exec_modules.index("shellprocess@hardware")
assert exec_modules.index("shellprocess@hardware") < exec_modules.index("bootloader")
for name in ("copy", "prepare", "desktop", "hardware"):
    if name == "desktop":
        path = "shellprocess-desktop.conf"
    elif name == "hardware":
        path = "shellprocess-hardware.conf"
    else:
        path = f"shellprocess-{name}.conf"
    with (root / "calamares/modules" / path).open(encoding="utf-8") as stream:
        conf = yaml.safe_load(stream)
    assert conf["dontChroot"] is True
    assert conf["script"]
desktop_script = yaml.safe_load(
    (root / "calamares/modules/shellprocess-desktop.conf").read_text(encoding="utf-8")
)["script"]
assert any("installer-desktop.sh ${ROOT} plasma" in command for command in desktop_script)

print("Calamares config validation passed.")
