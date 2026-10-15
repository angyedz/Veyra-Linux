#!/usr/bin/env python3
"""Read-only live KDE diagnostics under QEMU. No real disk access."""
import argparse
import importlib.util
import pathlib
import shutil
import sys
import tempfile
import subprocess

src = pathlib.Path(__file__).with_name("test-installed-qemu.py")
spec = importlib.util.spec_from_file_location("veyra_e2e_helpers", src)
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)

p = argparse.ArgumentParser()
p.add_argument("iso", type=pathlib.Path)
p.add_argument("--log", default="veyra-live-desktop.log")
args = p.parse_args()

qemu = shutil.which("qemu-system-x86_64")
qimg = shutil.which("qemu-img")
if not qemu or not qimg:
    p.error("QEMU binaries are missing")
with tempfile.TemporaryDirectory(prefix="veyra-desktop-diagnostics-") as tmp:
    disk = pathlib.Path(tmp, "scratch.qcow2")
    subprocess.run([qimg, "create", "-f", "qcow2", str(disk), "2G"], check=True)
    with open(args.log, "w", encoding="utf-8") as log:
        child = helpers.boot(qemu, str(disk), str(args.iso.resolve()), log, 400)
        try:
            helpers.login(child, 360)
            for cmd in (
                "rc-service sddm status || true",
                "rc-service elogind status || true",
                "id sddm; ls -ld /run/user/* /dev/dri/* || true",
                "ps -ef | grep -E 'sddm|Xorg|kwin|plasmashell' || true",
                "ls -l /usr/share/wayland-sessions /usr/share/xsessions || true",
                "cat /etc/sddm.conf.d/10-veyra-live.conf",
                "tail -n 100 /var/log/sddm.log /var/log/Xorg.0.log 2>&1 || true",
                "find /var/log -maxdepth 3 -iname '*sddm*' -o -iname '*xorg*' || true",
                "ls -l /etc/conf.d/sddm /etc/init.d/sddm",
                "rc-service sddm restart || true",
                "rc-service sddm status || true",
            ):
                print("Inspect:", cmd, flush=True)
                helpers.run_command(child, cmd, timeout=70)
        finally:
            child.close(force=True)
print("Live desktop diagnostics captured", flush=True)
