#!/usr/bin/env python3
"""Validate Veyra's Calamares integration before risking a real disk."""
from pathlib import Path
from xml.etree import ElementTree
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
branding = yaml.safe_load((root / "calamares/branding/veyra/branding.desc").read_text())
assert branding["slideshow"] == [
    "/etc/calamares/branding/veyra/desktop-plasma.svg"
]
assert branding["images"]["productIcon"] == "veyra-logo.svg"
assert branding["uploadServer"]["type"] == "none"
slide_path = root / "calamares/branding/veyra/desktop-plasma.svg"
assert slide_path.is_file()
slide = ElementTree.parse(slide_path).getroot()
svg_ns = "{http://www.w3.org/2000/svg}"
assert [node.text for node in slide.findall(f"{svg_ns}text")] == ["Veyra Linux"]
assert len(slide.findall(f"{svg_ns}g/{svg_ns}path")) == 3
assert not slide.findall(f"{svg_ns}rect")
assert (root / "branding/veyra-logo.svg").is_file()
instances = {instance["id"]: instance for instance in settings["instances"]}
assert "desktop" not in instances
assert instances["desktop-install"]["module"] == "shellprocess"

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
assert "gs[packagechooser_desktop]" not in str(
    yaml.safe_load((root / "calamares/modules/shellprocess-desktop.conf").read_text())
)

print("Calamares config validation passed.")
