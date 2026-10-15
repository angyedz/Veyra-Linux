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
seq = settings["sequence"]
assert any("show" in step for step in seq)
exec_modules = next(step["exec"] for step in seq if "exec" in step)
for name in ("partition", "mount", "shellprocess@copy", "shellprocess@prepare",
             "users", "services-openrc", "bootloader", "umount"):
    assert name in exec_modules, name
assert exec_modules.index("partition") < exec_modules.index("mount")
assert exec_modules.index("mount") < exec_modules.index("shellprocess@copy")
assert exec_modules.index("shellprocess@copy") < exec_modules.index("users")
assert exec_modules.index("shellprocess@prepare") < exec_modules.index("bootloader")
for name in ("copy", "prepare"):
    with (root / f"calamares/modules/shellprocess-{name}.conf").open(encoding="utf-8") as stream:
        conf = yaml.safe_load(stream)
    assert conf["dontChroot"] is True
    assert conf["script"]

print("Calamares config validation passed.")
