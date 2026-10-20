#!/usr/bin/env python3
"""Read-only live KDE diagnostics under QEMU. No real disk access."""
import argparse
import importlib.util
import pathlib
import shutil
import subprocess
import tempfile

src = pathlib.Path(__file__).with_name("test-installed-qemu.py")
spec = importlib.util.spec_from_file_location("veyra_e2e_helpers", src)
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)

p = argparse.ArgumentParser()
p.add_argument("iso", type=pathlib.Path)
p.add_argument("--log", default="veyra-live-desktop.log")
p.add_argument("--memory-mb", type=int, default=5120)
args = p.parse_args()

qemu = shutil.which("qemu-system-x86_64")
qimg = shutil.which("qemu-img")
if not qemu or not qimg:
    p.error("QEMU binaries are missing")
with tempfile.TemporaryDirectory(prefix="veyra-desktop-diagnostics-") as tmp:
    disk = pathlib.Path(tmp, "scratch.qcow2")
    subprocess.run([qimg, "create", "-f", "qcow2", str(disk), "2G"], check=True)
    with open(args.log, "w", encoding="utf-8") as log:
        child = helpers.boot(qemu, str(disk), str(args.iso.resolve()), log, 400,
                             memory_mb=args.memory_mb)
        try:
            helpers.login(child, 360)
            for cmd in (
                # Capture the failed service's logs below before asserting the
                # desktop process set; a failed SDDM start must not hide the cause.
                "rc-service sddm status || true",
                "rc-service elogind status || true",
                "rc-service zram-init status; grep -q '^/dev/zram' /proc/swaps",
                "visudo -c -f /etc/sudoers.d/veyra-live",
                "test -s /etc/polkit-1/rules.d/49-veyra-live.rules",
                "id sddm; ls -ld /run/user/* /dev/dri/* || true",
                "ps -ef | grep -E 'sddm|Xorg|kwin|plasmashell|startplasma' || true",
                "ls -l /usr/share/wayland-sessions /usr/share/xsessions || true",
                "cat /etc/sddm.conf.d/10-veyra-live.conf",
                "tail -n 100 /var/log/sddm.log /var/log/Xorg.0.log 2>&1 || true",
                "find /var/log -maxdepth 3 -iname '*sddm*' -o -iname '*xorg*' || true",
                "ls -l /etc/conf.d/sddm /etc/init.d/sddm",
                "su -s /bin/ash veyra -c 'sudo -n /bin/true'",
                "QT_QPA_PLATFORM=offscreen /usr/bin/calamares --help >/dev/null",
                "firefox --version",
                "echo '--- SDDM Wayland session output ---'; cat /home/veyra/.local/share/sddm/wayland-session.log 2>&1 || true; echo '--- Plasma watchdog output ---'; cat /home/veyra/.local/state/veyra-plasmashell.log 2>&1 || true; echo '--- Recent user logs and caches ---'; find /home/veyra/.local/share /home/veyra/.cache -type f -maxdepth 6 2>/dev/null | head -n 80; echo '--- Kernel memory/crash messages ---'; dmesg | grep -Ei 'out of memory|oom-kill|killed process|segfault|general protection' | tail -n 40 || true",
                "echo '--- Try the same Plasma Shell recovery as the live user ---'; su -s /bin/ash veyra -c 'nohup plasmashell --replace >/tmp/veyra-plasmashell-manual.log 2>&1 </dev/null &' ; sleep 15; cat /tmp/veyra-plasmashell-manual.log 2>&1 || true; ps -ef | grep -E 'sddm|kwin|plasmashell|startplasma|veyra-plasma-watchdog' || true",
                "found=0; for i in $(seq 1 30); do if ps -ef | grep -Eq '[k]win_(wayland|x11)' && ps -ef | grep -q '[p]lasmashell'; then found=1; break; fi; sleep 2; done; if test \"$found\" = 1; then echo 'Live Plasma compositor and shell are running'; else echo 'Live Plasma compositor or shell did not start'; false; fi",
            ):
                print("Inspect:", cmd, flush=True)
                helpers.run_command(child, cmd, timeout=70)
        finally:
            child.close(force=True)
print("Live desktop diagnostics captured", flush=True)
