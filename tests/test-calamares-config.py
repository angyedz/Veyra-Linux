#!/usr/bin/env python3
"""Validate Veyra's Calamares integration before risking a real disk."""
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
instances = {instance["id"]: instance for instance in settings["instances"]}
assert instances["desktop"]["module"] == "packagechooser"
assert instances["desktop"]["config"] == "packagechooser-desktop.conf"
with (root / "calamares/modules/packagechooser-desktop.conf").open(encoding="utf-8") as stream:
    chooser = yaml.safe_load(stream)
assert chooser["mode"] == "required"
assert chooser["method"] == "legacy"
assert chooser["default"] == "plasma"
assert [item["id"] for item in chooser["items"]] == ["plasma", "gnome", "xfce", "lxqt", "minimal"]
for item in chooser["items"]:
    assert Path(item["screenshot"].removeprefix("/etc/")).name
    assert (root / f"calamares/branding/veyra/desktop-{item['id']}.svg").exists()

seq = settings["sequence"]
assert any("show" in step for step in seq)
show_modules = next(step["show"] for step in seq if "show" in step)
assert show_modules.index("packagechooser@desktop") < show_modules.index("partition")
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
assert "gs[packagechooser_desktop]" in str(
    yaml.safe_load((root / "calamares/modules/shellprocess-desktop.conf").read_text())
)

print("Calamares config validation passed.")
