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
                "cat /etc/sddm.conf.d/zz-veyra-live.conf",
                "cat /etc/sddm.conf.d/plasma-wayland.conf 2>/dev/null || true",
                "cat /etc/pam.d/sddm 2>/dev/null || true",
                "cat /etc/init.d/sddm /etc/conf.d/sddm 2>/dev/null || true",
                "ls -ld /run/user/$(id -u sddm) /run/user/$(id -u veyra) 2>&1 || true",
                "tail -n 100 /var/log/sddm.log /var/log/Xorg.0.log 2>&1 || true",
                "grep -iE 'sddm|kwin|plasma' /var/log/messages 2>/dev/null | tail -n 120 || true",
                "find /home/veyra/.local/share /home/veyra/.cache -maxdepth 5 -type f "
                "\\( -iname '*sddm*' -o -iname '*session*' -o -iname '*.log' \\) -print 2>/dev/null || true",
                "for f in /home/veyra/.local/share/sddm/* /home/veyra/.cache/sddm/*; do "
                "[ -f \"$f\" ] && { echo \"===== $f\"; tail -n 120 \"$f\"; }; done; true",
                "find /var/log -maxdepth 3 -iname '*sddm*' -o -iname '*xorg*' || true",
                "ls -l /etc/conf.d/sddm /etc/init.d/sddm",
                "rc-service sddm restart || true",
                "rc-service sddm status || true",
                "mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix && "
                "rc-service sddm restart || true; sleep 5; "
                "rc-service sddm status || true; "
                "tail -n 80 /var/log/sddm.log /home/veyra/.local/share/sddm/wayland-session.log 2>&1 || true",
            ):
                print("Inspect:", cmd, flush=True)
                helpers.run_command(child, cmd, timeout=70)
        finally:
            child.close(force=True)
print("Live desktop diagnostics captured", flush=True)
