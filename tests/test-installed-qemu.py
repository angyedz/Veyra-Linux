#!/usr/bin/env python3
"""Safely install Veyra from its live ISO into a disposable QEMU virtual disk.

This tests the same distro shell scripts Calamares calls, not GUI clicks in
Calamares. Destructive commands are executed ONLY inside QEMU on /dev/vda,
which is backed by a fresh temporary qcow2 file created here.
"""
import argparse
import base64
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

import pexpect


def install_script(desktop):
    if desktop not in {"plasma", "gnome", "xfce", "lxqt"}:
        raise ValueError("Invalid desktop")
    return """#!/bin/sh
set -eux
target=/mnt/veyra-e2e
disk=/dev/vda
# A guard against accidentally touching the live boot ISO or host disks.
test -r /etc/veyra-release
test -b "$disk"
test "$(cat /sys/block/vda/removable)" = 0
test -e /dev/sr0
apk info -e veyra-calamares
parted -s "$disk" mklabel msdos
parted -s "$disk" mkpart primary ext4 1MiB 100%
parted -s "$disk" set 1 boot on
partprobe "$disk" || true
sleep 3
test -b /dev/vda1
mkfs.ext4 -F /dev/vda1
mkdir -p "$target"
mount /dev/vda1 "$target"
/usr/local/lib/veyra/installer-copy.sh "$target"
for dir in dev proc sys run; do mkdir -p "$target/$dir"; done
mount --rbind /dev "$target/dev"
mount --make-rslave "$target/dev"
mount -t proc proc "$target/proc"
mount --rbind /sys "$target/sys"
mount --make-rslave "$target/sys"
mount -t tmpfs tmpfs "$target/run"
/usr/local/lib/veyra/installer-prepare.sh "$target"
/usr/local/lib/veyra/installer-desktop.sh "$target" DESKTOP
/usr/local/lib/veyra/installer-hardware.sh "$target"
echo 'root:veyra-test' | chroot "$target" chpasswd
chroot "$target" adduser -D -s /bin/ash e2euser
echo 'e2euser:veyra-test' | chroot "$target" chpasswd
uuid=$(blkid -s UUID -o value /dev/vda1)
printf 'UUID=%s / ext4 defaults 0 1\\n' "$uuid" > "$target/etc/fstab"
# Keep the installed guest observable over serial; this affects only the
# throwaway QEMU disk, not the distributed installer or end-user defaults.
printf '%s\\n' 'GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200"' >> "$target/etc/default/grub"
chroot "$target" grub-install --target=i386-pc --recheck /dev/vda
chroot "$target" grub-mkconfig -o /boot/grub/grub.cfg
test -s "$target/boot/grub/grub.cfg"
grep -q 'menuentry' "$target/boot/grub/grub.cfg"
test -s "$target/boot/vmlinuz-lts"
test -s "$target/boot/initramfs-lts"
test "$(cat "$target/etc/veyra/desktop")" = DESKTOP
# Check installed service is enabled for the chosen desktop.
test -e "$target/etc/runlevels/default/SERVICE"
sync
echo VEYRA_E2E_INSTALL_SUCCESS
""".replace("DESKTOP", desktop).replace(
        "SERVICE", "lightdm" if desktop == "xfce"
        else "gdm" if desktop == "gnome" else "sddm"
    )


def boot(qemu, disk, iso, logfile, timeout, installed=False):
    cmd = [
        qemu, "-machine", "accel=tcg", "-m", "6144", "-smp", "2",
        "-vga", "virtio", "-display", "none",
        "-monitor", "none", "-serial", "stdio", "-no-reboot",
        "-nic", "user,model=virtio-net-pci",
        "-drive", f"file={disk},format=qcow2,if=virtio",
        "-boot", "c" if installed else "d",
    ]
    if not installed:
        cmd += ["-cdrom", iso]
    print("Starting disposable QEMU guest: " + ("installed image" if installed else "live ISO"), flush=True)
    child = pexpect.spawn(cmd[0], cmd[1:], timeout=timeout, encoding="utf-8",
                          codec_errors="replace")
    child.logfile_read = logfile
    return child


def login(child, timeout):
    # Wait for a REAL getty, never mistake the APK download progress bar
    # (which prints lots of '#') for an interactive root shell.
    prompt = r"(?:^|[\r\n])(?:[A-Za-z0-9_.-]+ )?login: *"
    child.expect(prompt, timeout=timeout)
    child.sendline("root")
    index = child.expect(
        [r"Password:", r"(?:^|[\r\n])[A-Za-z0-9_.-]+:[^\r\n]{0,50}# ?", r"Login incorrect",
         pexpect.EOF, pexpect.TIMEOUT],
        timeout=45,
    )
    if index == 0:
        child.sendline("veyra-test")
        child.expect(r"(?m)^[^\r\n]{0,80}# *$", timeout=45)
    elif index != 1:
        raise RuntimeError("Guest root login failed")

    # Prove we are talking to the shell, not an echoed command line.
    child.sendline("printf '\\nVEYRA_SHELL_READY\\n'")
    child.expect(r"(?:^|[\r\n])VEYRA_SHELL_READY(?:\r|\n)", timeout=35)

def run_command(child, command, timeout=300):
    # Appends a unique marker with exit code, does not depend on prompt echoes.
    marker = "VEYRA_CHECK_RETURN="
    child.sendline(command + f"; printf '\\n{marker}%d\\n' $?")
    idx = child.expect([marker + r"(\d+)", pexpect.EOF, pexpect.TIMEOUT], timeout=timeout)
    if idx != 0:
        raise RuntimeError("Guest shell timed out while executing a command")
    code = int(child.match.group(1))
    if code:
        raise RuntimeError(f"Guest command returned {code}: {command[:100]}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("iso", type=pathlib.Path)
    parser.add_argument("--desktop", choices=["plasma", "gnome", "xfce", "lxqt"],
                        default="plasma")
    parser.add_argument("--log-dir", type=pathlib.Path, default=pathlib.Path("."))
    args = parser.parse_args()
    args.log_dir.mkdir(parents=True, exist_ok=True)
    if not args.iso.is_file():
        parser.error("No ISO provided")
    qemu = shutil.which("qemu-system-x86_64")
    qimg = shutil.which("qemu-img")
    if not qemu or not qimg:
        parser.error("QEMU and qemu-img are required")
    with tempfile.TemporaryDirectory(prefix="veyra-e2e-") as tmp:
        disk = pathlib.Path(tmp) / "test-disk.qcow2"
        subprocess.run([qimg, "create", "-f", "qcow2", str(disk), "20G"], check=True)
        with (args.log_dir / "veyra-install-console.log").open("w") as log:
            child = boot(qemu, str(disk), str(args.iso.resolve()), log, 400)
            try:
                login(child, 360)
                payload = base64.b64encode(install_script(args.desktop).encode()).decode()
                run_command(child, "printf '%s' '" + payload + "' | base64 -d > /tmp/e2e-install.sh", 30)
                # A shell in QEMU runs everything on ONLY the blank /dev/vda disk.
                # It verifies actual installations/downloads rather than mocked calls.
                run_command(child, "sh /tmp/e2e-install.sh", timeout=1500)
                run_command(child, "test -s /mnt/veyra-e2e/boot/grub/grub.cfg", 30)
                print("Installation completed: target grub.cfg, kernel and services verified", flush=True)
            finally:
                child.close(force=True)

        with (args.log_dir / "veyra-installed-console.log").open("w") as log:
            child = boot(qemu, str(disk), None, log, 400, installed=True)
            try:
                login(child, 240)
                run_command(child, "test -r /etc/veyra/desktop && cat /etc/veyra/desktop", 30)
                run_command(child, "test -s /boot/grub/grub.cfg", 30)
                print(f"VEYRA_E2E_SUCCESS: clean virtual disk boots installed {args.desktop}", flush=True)
            finally:
                child.close(force=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"VEYRA_E2E_FAILED: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
