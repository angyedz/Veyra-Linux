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


def install_script(desktop, firmware="bios"):
    if desktop not in {"plasma", "gnome", "xfce", "lxqt", "minimal"}:
        raise ValueError("Invalid desktop")
    if firmware not in {"bios", "uefi"}:
        raise ValueError("Invalid firmware")
    service_check = (
        'test ! -e "$target/etc/runlevels/default/sddm" && '
        'test ! -e "$target/etc/runlevels/default/gdm" && '
        'test ! -e "$target/etc/runlevels/default/lightdm"'
        if desktop == "minimal" else
        'test -e "$target/etc/runlevels/default/SERVICE"'
    )
    if firmware == "uefi":
        disk_setup = """parted -s "$disk" mklabel gpt
parted -s "$disk" mkpart ESP fat32 1MiB 513MiB
parted -s "$disk" set 1 esp on
parted -s "$disk" mkpart primary ext4 513MiB 100%
partprobe "$disk" || true
sleep 3
test -b /dev/vda1
test -b /dev/vda2
mkfs.vfat -F32 /dev/vda1
mkfs.ext4 -F /dev/vda2
mkdir -p "$target"
mount /dev/vda2 "$target"
mkdir -p "$target/boot/efi"
mount /dev/vda1 "$target/boot/efi\""""
        fstab_setup = (
            "root_uuid=$(blkid -s UUID -o value /dev/vda2)\n"
            "efi_uuid=$(blkid -s UUID -o value /dev/vda1)\n"
            "printf 'UUID=%s / ext4 defaults 0 1\\n' \"$root_uuid\" > \"$target/etc/fstab\"\n"
            "printf 'UUID=%s /boot/efi vfat defaults 0 2\\n' \"$efi_uuid\" >> \"$target/etc/fstab\""
        )
        grub_install = "chroot \"$target\" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Veyra --removable --no-nvram"
        efi_check = 'test -s "$target/boot/efi/EFI/BOOT/BOOTX64.EFI"'
    else:
        disk_setup = """parted -s "$disk" mklabel msdos
parted -s "$disk" mkpart primary ext4 1MiB 100%
parted -s "$disk" set 1 boot on
partprobe "$disk" || true
sleep 3
test -b /dev/vda1
mkfs.ext4 -F /dev/vda1
mkdir -p "$target"
mount /dev/vda1 "$target\""""
        fstab_setup = (
            "root_uuid=$(blkid -s UUID -o value /dev/vda1)\n"
            "printf 'UUID=%s / ext4 defaults 0 1\\n' \"$root_uuid\" > \"$target/etc/fstab\""
        )
        grub_install = 'chroot "$target" grub-install --target=i386-pc --recheck /dev/vda'
        efi_check = ":"
    return """#!/bin/sh
set -eux
target=/mnt/veyra-e2e
disk=/dev/vda
# A guard against accidentally touching the live boot ISO or host disks.
test -r /etc/veyra-release
test -x /usr/bin/vpkg
apk info -e vpkg
test -x /usr/bin/veyra-glenv
apk info -e veyra-glenv
test -b "$disk"
test "$(cat /sys/block/vda/removable)" = 0
test -e /dev/sr0
apk info -e veyra-calamares
DISK_SETUP
/usr/local/lib/veyra/installer-copy.sh "$target"
for dir in dev proc sys run; do mkdir -p "$target/$dir"; done
mount --rbind /dev "$target/dev"
mount --make-rslave "$target/dev"
mount -t proc proc "$target/proc"
mount --rbind /sys "$target/sys"
mount --make-rslave "$target/sys"
mount -t tmpfs tmpfs "$target/run"
/usr/local/lib/veyra/installer-prepare.sh "$target"
test ! -e "$target/etc/polkit-1/rules.d/49-veyra-live.rules"
test "$(stat -c %a "$target/tmp")" -eq 1777
test "$(wc -c < "$target/etc/machine-id")" -eq 33
grep -Eq '^[0-9a-f]{32}$' "$target/etc/machine-id"
chroot "$target" apk info -e vpkg
chroot "$target" apk info -e veyra-glenv
/usr/local/lib/veyra/installer-desktop.sh "$target" DESKTOP
/usr/local/lib/veyra/installer-hardware.sh "$target"
echo 'root:veyra-test' | chroot "$target" chpasswd
chroot "$target" adduser -D -s /bin/ash e2euser
echo 'e2euser:veyra-test' | chroot "$target" chpasswd
if [ "DESKTOP" = plasma ]; then
    test -s "$target/home/e2euser/.config/kwinrc"
    test -s "$target/home/e2euser/.config/autostart/veyra-plasma-watchdog.desktop"
    grep -q '^Enabled=false$' "$target/home/e2euser/.config/kwinrc"
    grep -q '^Exec=/usr/local/lib/veyra/plasma-watchdog.sh$' "$target/home/e2euser/.config/autostart/veyra-plasma-watchdog.desktop"
    # Enable automatic login only on this disposable test disk so the test
    # exercises the graphical session without keyboard or display automation.
    cat > "$target/etc/sddm.conf.d/90-veyra-e2e.conf" <<'SDDM'
[Autologin]
User=e2euser
Session=plasma.desktop
Relogin=false
SDDM
fi
# Mirror Calamares' services-openrc step for this script-driven install.
for service in dbus elogind networkmanager nix-daemon; do
    chroot "$target" rc-update add "$service" default
done
FSTAB_SETUP
# Keep the installed guest observable over serial; this affects only the
# throwaway QEMU disk, not the distributed installer or end-user defaults.
printf '%s\\n' 'GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} console=tty0 console=ttyS0,115200"' >> "$target/etc/default/grub"
GRUB_INSTALL
chroot "$target" grub-mkconfig -o /boot/grub/grub.cfg
test -s "$target/boot/grub/grub.cfg"
grep -q 'menuentry' "$target/boot/grub/grub.cfg"
test -s "$target/boot/vmlinuz-lts"
grep -Eq '^[[:xdigit:]]{32}$' "$target/etc/machine-id"
test ! -e "$target/etc/veyra-release"
test ! -e "$target/etc/runlevels/default/veyra-live-mode"
test -s "$target/boot/initramfs-lts"
grep -q 'rootfstype=ext4' "$target/etc/default/grub"
grep -q 'ext4 virtio nvme' "$target/etc/mkinitfs/mkinitfs.conf"
EFI_CHECK
test "$(cat "$target/etc/veyra/desktop")" = DESKTOP
# Check the selected display manager, or verify a console-only setup.
SERVICE_CHECK
for service in dbus elogind networkmanager nix-daemon; do
    test -e "$target/etc/runlevels/default/$service"
done
sync
echo VEYRA_E2E_INSTALL_SUCCESS
""".replace("DISK_SETUP", disk_setup).replace("FSTAB_SETUP", fstab_setup).replace(
        "GRUB_INSTALL", grub_install).replace("EFI_CHECK", efi_check).replace(
        "DESKTOP", desktop).replace("SERVICE_CHECK", service_check).replace(
        "SERVICE", "lightdm" if desktop == "xfce"
        else "gdm" if desktop == "gnome" else "sddm"
    )


def boot(qemu, disk, iso, logfile, timeout, installed=False, firmware="bios",
         ovmf_code=None, ovmf_vars=None, memory_mb=6144):
    machine = "q35,accel=tcg" if firmware == "uefi" else "accel=tcg"
    cmd = [
        qemu, "-machine", machine, "-m", str(memory_mb), "-smp", "2",
        "-vga", "virtio", "-display", "none",
        "-monitor", "none", "-serial", "stdio", "-no-reboot",
        "-nic", "user,model=virtio-net-pci",
        "-drive", f"file={disk},format=qcow2,if=virtio",
        "-boot", "c" if installed else "d",
    ]
    if firmware == "uefi":
        if not ovmf_code or not ovmf_vars:
            raise ValueError("UEFI boot requires OVMF code and variable-store files")
        cmd += [
            "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={ovmf_code}",
            "-drive", f"if=pflash,format=raw,unit=1,file={ovmf_vars}",
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
    prompt = r"(?:^|[\r\n])(?:[A-Za-z0-9_.()-]+ )?login: *"
    child.expect(prompt, timeout=timeout)
    child.sendline("root")
    index = child.expect(
        [r"Password:", r"(?:^|[\r\n])[A-Za-z0-9_.()-]+:[^\r\n]{0,50}# ?", r"Login incorrect",
         pexpect.EOF, pexpect.TIMEOUT],
        timeout=45,
    )
    if index == 0:
        child.sendline("veyra-test")
        child.expect(r"(?:^|[\r\n])[A-Za-z0-9_.()-]+:[^\r\n]{0,50}# ?", timeout=45)
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
        output = getattr(child, "before", "")[-1200:].replace("\r", "")
        raise RuntimeError(
            f"Guest command returned {code}: {command[:100]}; "
            f"guest output tail: {output!r}"
        )



def upload_script(child, content, remote_path):
    """Upload a script over a serial TTY without hitting MAX_CANON (4096)."""
    # All remote paths are fixed internal allowlist values.
    if not (
        remote_path == "/tmp/e2e-install.sh"
        or remote_path.startswith("/usr/local/lib/veyra/installer-")
        or remote_path == "/usr/local/lib/veyra/setup-pkgrepo.sh"
        or remote_path in {
            "/usr/local/lib/veyra/veyra-atomic-convert.sh",
            "/usr/local/lib/veyra/veyra-deployment.sh",
            "/usr/local/lib/veyra/veyra-initramfs-select.sh",
            "/usr/local/lib/veyra/build-veyra-init.sh",
            "/usr/local/lib/veyra/veyra-bootctl.py",
        }
    ):
        raise ValueError("Unexpected remote script path")
    payload = base64.b64encode(content).decode("ascii")
    run_command(child, ": > /tmp/veyra-e2e-transfer.b64", 30)
    for pos in range(0, len(payload), 512):
        chunk = payload[pos:pos + 512]
        run_command(
            child,
            "printf '%s' '" + chunk + "' >> /tmp/veyra-e2e-transfer.b64",
            45,
        )
    syntax_check = ("test -s " if remote_path.endswith(".py") else "sh -n ")
    run_command(
        child,
        "base64 -d /tmp/veyra-e2e-transfer.b64 > " + remote_path
        + " && " + syntax_check + remote_path,
        45,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("iso", type=pathlib.Path)
    parser.add_argument("--desktop", choices=["plasma", "gnome", "xfce", "lxqt", "minimal"],
                        default="plasma")
    parser.add_argument("--firmware", choices=["bios", "uefi"], default="bios")
    parser.add_argument("--log-dir", type=pathlib.Path, default=pathlib.Path("."))
    parser.add_argument("--require-glenv-manager", action="store_true",
                        help="require the opt-in musl manager on live and installed Veyra")
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
        ovmf_code = ovmf_vars = None
        if args.firmware == "uefi":
            code_candidates = [
                (pathlib.Path("/usr/share/OVMF/OVMF_CODE_4M.fd"),
                 pathlib.Path("/usr/share/OVMF/OVMF_VARS_4M.fd")),
                (pathlib.Path("/usr/share/OVMF/OVMF_CODE.fd"),
                 pathlib.Path("/usr/share/OVMF/OVMF_VARS.fd")),
            ]
            firmware_pair = next(
                ((code, variables) for code, variables in code_candidates
                 if code.is_file() and variables.is_file()), None
            )
            if firmware_pair is None:
                parser.error("UEFI tests require the ovmf package and OVMF code/variable files")
            ovmf_code = str(firmware_pair[0])
            ovmf_vars = pathlib.Path(tmp) / "OVMF_VARS.fd"
            shutil.copyfile(firmware_pair[1], ovmf_vars)
        with (args.log_dir / "veyra-install-console.log").open("w") as log:
            child = boot(qemu, str(disk), str(args.iso.resolve()), log, 400,
                         firmware=args.firmware, ovmf_code=ovmf_code, ovmf_vars=ovmf_vars)
            try:
                login(child, 360)
                if args.require_glenv_manager:
                    run_command(child, "test -x /usr/local/lib/veyra/glenv-manager && "
                                "/usr/local/lib/veyra/glenv-manager version && "
                                "test -f /usr/local/lib/veyra/glenv-boot-pin.sh && "
                                "test -f /usr/local/lib/veyra/glenv-boot-mount.sh", 45)
                # The cached-ISO workflow tests current installer scripts:
                # patch them into the disposable live guest before installing.
                # Always copy the matching Veyra trust bootstrap script too:
                # older cached ISOs lack setup-pkgrepo.sh altogether.
                srcroot = pathlib.Path(__file__).resolve().parents[1]
                for script in (
                    "installer-copy.sh", "installer-prepare.sh",
                    "installer-desktop.sh", "installer-hardware.sh",
                    "setup-pkgrepo.sh",
                ):
                    upload_script(
                        child,
                        (srcroot / "scripts" / script).read_bytes(),
                        "/usr/local/lib/veyra/" + script,
                    )
                upload_script(child, install_script(args.desktop, args.firmware).encode(),
                              "/tmp/e2e-install.sh")
                # A shell in QEMU runs everything on ONLY the blank /dev/vda disk.
                # It verifies actual installations/downloads rather than mocked calls.
                run_command(child, "sh /tmp/e2e-install.sh", timeout=1500)
                run_command(child, "test -s /mnt/veyra-e2e/boot/grub/grub.cfg", 30)
                run_command(child, "test ! -e /mnt/veyra-e2e/etc/sudoers.d/veyra-live", 30)
                print("Installation completed: target grub.cfg, kernel and services verified", flush=True)
            finally:
                child.close(force=True)

        with (args.log_dir / "veyra-installed-console.log").open("w") as log:
            child = boot(qemu, str(disk), None, log, 400, installed=True,
                         firmware=args.firmware, ovmf_code=ovmf_code, ovmf_vars=ovmf_vars)
            try:
                login(child, 240)
                if args.require_glenv_manager:
                    run_command(child, "test -x /usr/local/lib/veyra/glenv-manager && "
                                "/usr/local/lib/veyra/glenv-manager version && "
                                "test -f /usr/local/lib/veyra/glenv-boot-pin.sh && "
                                "test -f /usr/local/lib/veyra/glenv-boot-mount.sh", 45)
                run_command(child, "test -r /etc/veyra/desktop && cat /etc/veyra/desktop", 30)
                run_command(child, "test -x /usr/bin/vpkg && vpkg --version", 30)
                run_command(child, "test -x /usr/bin/veyra-glenv", 30)
                run_command(child, "test ! -e /etc/polkit-1/rules.d/49-veyra-live.rules", 30)
                run_command(child, "test -s /boot/grub/grub.cfg", 30)
                run_command(child, "test -s /etc/machine-id && rc-service dbus status", 60)
                if args.firmware == "uefi":
                    run_command(child, "test -d /sys/firmware/efi", 30)
                    run_command(child, "test -s /boot/efi/EFI/BOOT/BOOTX64.EFI", 30)
                if args.desktop == "plasma":
                    run_command(
                        child,
                        "found=0; for i in $(seq 1 45); do if ps -ef | grep -Eq '[k]win_(wayland|x11)' && ps -ef | grep -q '[p]lasmashell'; then found=1; break; fi; sleep 2; done; if test \"$found\" = 1; then echo 'Installed Plasma compositor and shell are running'; else echo 'Installed Plasma compositor or shell did not start'; cat /home/e2euser/.local/share/sddm/wayland-session.log 2>&1 || true; ps -ef | grep -E 'sddm|kwin|plasma|startplasma' || true; false; fi",
                        110,
                    )
                print(f"VEYRA_E2E_SUCCESS: clean virtual disk boots installed {args.desktop}", flush=True)
            finally:
                child.close(force=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"VEYRA_E2E_FAILED: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
