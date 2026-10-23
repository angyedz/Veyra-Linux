#!/usr/bin/env python3
"""Graphically install Veyra in disposable QEMU and reach its Plasma session.

All input is sent to the QEMU window under Xvfb. The guest has one newly
created qcow2 disk; no host display or host storage is exposed to it.
"""
import argparse
import csv
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

from calamares_gui_state import is_live_desktop


class Gui:
    def __init__(self, window, output_dir, label):
        self.window = window
        self.output_dir = output_dir
        self.label = label
        self.serial_log_path = output_dir / f"{label}-serial.log"
        self.last_text = ""
        self.wake_toggle = False

    def command(self, *args, check=True, timeout=30):
        result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
        if check and result.returncode:
            raise RuntimeError(
                f"Command failed ({result.returncode}): {' '.join(args)}\n"
                f"{result.stdout}\n{result.stderr}"
            )
        return result

    def screenshot(self, name=None):
        geometry = self.command(
            "xdotool", "getwindowgeometry", "--shell", str(self.window)
        ).stdout
        size = {
            key: int(value)
            for key, value in (line.split("=", 1) for line in geometry.splitlines()
                               if "=" in line)
        }
        self.wake_toggle = not self.wake_toggle
        wake_x = size["WIDTH"] - (32 if self.wake_toggle else 33)
        wake_y = size["HEIGHT"] - 64
        self.command("xdotool", "mousemove", "--sync", "--window", str(self.window),
                     str(wake_x), str(wake_y))
        path = self.output_dir / (name or f"{self.label}-screen.png")
        if os.environ.get("VEYRA_QEMU_CAPTURE_ROOT") == "1":
            crop = (f"{size['WIDTH']}x{size['HEIGHT']}+{size['X']}+{size['Y']}")
            self.command("import", "-window", "root", "-crop", crop,
                         "+repage", str(path), timeout=30)
        else:
            self.command("import", "-window", str(self.window), str(path), timeout=30)
        result = self.command("tesseract", str(path), "stdout", "--psm", "11", "tsv")
        words, boxes = [], []
        for row in csv.DictReader(result.stdout.splitlines(), delimiter="\t"):
            word = row.get("text", "").strip()
            if not word:
                continue
            words.append(word)
            try:
                boxes.append((word, int(row["left"]), int(row["top"]),
                              int(row["width"]), int(row["height"])))
            except (KeyError, ValueError):
                pass
        self.last_text = " ".join(words)
        return self.last_text, boxes

    def focus(self):
        self.command("xdotool", "windowraise", str(self.window), check=False)
        self.command("xdotool", "windowfocus", "--sync", str(self.window))

    def key(self, value):
        self.focus()
        self.command("xdotool", "key", "--clearmodifiers", value)

    def type_text(self, value):
        self.focus()
        self.command("xdotool", "type", "--clearmodifiers", "--delay", "20", value)

    def wait_text(self, terms, timeout, description):
        terms = [term.lower() for term in terms]
        deadline = time.monotonic() + timeout
        started = time.monotonic()
        while time.monotonic() < deadline:
            text, _ = self.screenshot()
            if any(term in text.lower() for term in terms):
                print(f"{self.label}: found {description}: {text[:300]}", flush=True)
                return text
            if (self.label == "live"
                    and description == "live Plasma desktop and installer shortcut"
                    and time.monotonic() - started >= 180
                    and self.serial_log_path.is_file()):
                serial = self.serial_log_path.read_text(encoding="utf-8", errors="replace")
                if "ERROR: sddm failed to start" in serial:
                    raise RuntimeError(
                        "SDDM did not produce the live Plasma desktop; "
                        f"serial tail: {serial[-2400:]}"
                    )
            if (self.label == "live"
                    and description == "Calamares welcome page from diagnostic autostart"
                    and self.serial_log_path.is_file()):
                serial = self.serial_log_path.read_text(encoding="utf-8", errors="replace")
                if "VEYRA_DIAGNOSTIC_AUTOSTART: wrapper exited status=" in serial:
                    raise RuntimeError(
                        "Diagnostic Calamares launcher exited before the welcome page; "
                        f"guest serial tail: {serial[-4000:]}"
                    )
            time.sleep(2)
        raise RuntimeError(
            f"Timed out waiting for {description}; last visible text: {self.last_text[:1200]}"
        )

    def click_word(self, label, lower_right=False, double=False):
        text, boxes = self.screenshot()
        geometry = self.command(
            "xdotool", "getwindowgeometry", "--shell", str(self.window)
        ).stdout
        size = {
            key: int(value)
            for key, value in (line.split("=", 1) for line in geometry.splitlines()
                               if "=" in line)
        }
        matches = [box for box in boxes if box[0].lower().strip(".,:;!?") == label.lower()]
        if lower_right:
            matches = [box for box in matches
                       if box[1] >= 0.55 * size["WIDTH"]
                       and box[2] >= 0.65 * size["HEIGHT"]]
        if not matches:
            raise RuntimeError(f"Could not find {label!r}; visible text: {text[:1200]}")
        word, x, y, width, height = sorted(matches, key=lambda box: (box[2], box[1]))[-1]
        self.click_at(x + max(width // 2, 1), y + max(height // 2, 1), double=double)
        print(f"{self.label}: clicked {word!r} at {x},{y}", flush=True)

    def click_at(self, x, y, double=False):
        self.focus()
        self.command("xdotool", "mousemove", "--sync", "--window", str(self.window),
                     str(x), str(y))
        if double:
            self.command("xdotool", "click", "--repeat", "2", "--delay", "250", "1")
        else:
            self.command("xdotool", "click", "1")
        time.sleep(2)

    def click_next(self):
        self.wait_text(["Next"], 60, "Calamares navigation")
        self.click_word("Next", lower_right=True)


def wait_window(title, process, timeout=360):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"QEMU exited before display appeared (status {process.returncode})")
        result = subprocess.run(
            ["xdotool", "search", "--onlyvisible", "--name", title],
            text=True, capture_output=True,
        )
        if result.returncode == 0 and result.stdout.strip():
            return int(result.stdout.strip().splitlines()[-1])
        time.sleep(2)
    raise RuntimeError("QEMU display window did not appear")


def boot(qemu, disk, log_path, iso=None):
    command = [
        qemu, "-name", "veyra-calamares-e2e", "-machine",
        f"accel={os.environ.get('VEYRA_QEMU_ACCEL', 'tcg')}",
        # A USB tablet reports absolute coordinates. QEMU's default relative
        # PS/2 mouse grabs and recenters the pointer on the first click, which
        # sends desktop-icon clicks to the middle of the guest screen.
        "-usb", "-device", "usb-tablet",
        "-m", "6144", "-smp", "4", "-vga",
        os.environ.get("VEYRA_QEMU_VGA", "virtio"), "-display",
        os.environ.get("VEYRA_QEMU_DISPLAY", "sdl"),
        "-monitor", "none", "-serial", f"file:{log_path}", "-no-reboot",
        "-nic", "user,model=virtio-net-pci",
        "-drive", f"file={disk},format=qcow2,if=virtio", "-boot", "c" if iso is None else "d",
    ]
    if iso is not None:
        command += ["-cdrom", str(iso)]
    qemu_log = log_path.with_name(f"{log_path.stem}-qemu.log").open("w", encoding="utf-8")
    log_path.touch()
    return subprocess.Popen(command, stdout=qemu_log, stderr=subprocess.STDOUT), qemu_log


def stop(process, log):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
    log.close()


def require_tools(parser):
    for name in ("qemu-system-x86_64", "qemu-img", "xdotool", "import", "tesseract"):
        if not shutil.which(name):
            parser.error(f"Required GUI test tool is missing: {name}")


def launch_calamares(gui):
    gui.wait_text(["Install Veyra Linux", "Install Veyra"], 900,
                  "live Plasma desktop and installer shortcut")
    time.sleep(10)
    # Plasma is configured for double-click activation. The QEMU USB tablet
    # preserves the absolute click position across the guest input.
    gui.click_word("Install", double=True)
    try:
        gui.wait_text(["Welcome", "Location"], 30, "Calamares welcome page")
        return "desktop"
    except RuntimeError as desktop_error:
        gui.screenshot("live-after-desktop-timeout.png")
        print(f"live: desktop shortcut did not open Calamares: {desktop_error}", flush=True)

    # Use the visible application launcher to separate desktop-shortcut
    # handling from the installed system-menu entry and its Exec command.
    gui.click_at(24, 796)
    time.sleep(1)
    gui.type_text("Install Veyra Linux")
    gui.screenshot("live-application-menu-search.png")
    gui.key("Return")
    try:
        gui.wait_text(["Welcome", "Location"], 90,
                      "Calamares welcome page via Plasma application launcher")
    except RuntimeError as error:
        serial = ""
        if gui.serial_log_path.is_file():
            serial = gui.serial_log_path.read_text(encoding="utf-8", errors="replace")[-3000:]
        raise RuntimeError(f"{error}; guest serial tail: {serial}") from error
    return "application-menu"


def install_via_gui(gui):
    gui.click_next()
    gui.wait_text(["Locale", "Location", "Time Zone", "Timezone"], 90, "location page")
    gui.click_next()
    gui.wait_text(["Keyboard"], 90, "keyboard page")
    gui.click_next()
    gui.wait_text(["Partition", "Disk"], 90, "partition page")
    gui.click_word("Erase")
    gui.click_next()
    gui.wait_text(["Users", "User"], 90, "user creation page")

    # On entry, Calamares focuses the first account field. The remaining fields
    # follow the module's full-name, login, hostname, password order.
    gui.key("ctrl+a")
    gui.type_text("Veyra CI")
    for value in ("veyra-ci", "veyra-ci", "veyra-ci-password", "veyra-ci-password"):
        gui.key("Tab")
        gui.type_text(value)
    gui.click_next()
    gui.wait_text(["Summary"], 90, "installation summary")
    gui.screenshot("calamares-summary-before-install.png")
    try:
        gui.click_word("Install", lower_right=True)
    except RuntimeError:
        # OCR can miss the button icon or merge its label with Summary text.
        geometry = gui.command(
            "xdotool", "getwindowgeometry", "--shell", str(gui.window)
        ).stdout
        size = {
            key: int(value)
            for key, value in (line.split("=", 1) for line in geometry.splitlines()
                               if "=" in line)
        }
        x = round(size["WIDTH"] * 0.783)
        # Summary expands Calamares vertically by about one row; target the
        # lower primary button rather than the same y-position as Next.
        y = round(size["HEIGHT"] * 0.91)
        gui.click_at(x, y)
        print(f"live: clicked summary primary button at {x},{y}", flush=True)
    gui.screenshot("calamares-summary-after-install-click.png")
    deadline = time.monotonic() + 3300
    confirmation_handled = False
    completion_terms = ("restart", "finished", "all done", "installation complete")
    while time.monotonic() < deadline:
        text, _ = gui.screenshot()
        lowered = text.lower()
        installer_restarted = (
            "welcome to the veyra linux development installer" in lowered
        )
        returned_to_desktop = is_live_desktop(lowered)
        if confirmation_handled and (installer_restarted or returned_to_desktop):
            serial = ""
            if gui.serial_log_path.is_file():
                serial = gui.serial_log_path.read_text(
                    encoding="utf-8", errors="replace"
                )[-3000:]
            if installer_restarted:
                raise RuntimeError(
                    "Calamares returned to its Welcome page after disk changes "
                    f"were confirmed; guest serial tail: {serial}"
                )
            print(
                "live: Calamares closed and returned to the live desktop after "
                "disk changes were confirmed; checking the installed disk next",
                flush=True,
            )
            return True
        if any(term in lowered for term in completion_terms):
            break
        if (not confirmation_handled and (
                "are you sure" in lowered
                or "confirm" in lowered
                or "continue with installation" in lowered
                or "install now" in lowered)):
            gui.click_word("Now")
            print("live: confirmed Calamares disk changes", flush=True)
            confirmation_handled = True
        time.sleep(5)
    else:
        raise RuntimeError(f"Timed out waiting for installation completion: {gui.last_text[:1200]}")
    gui.screenshot("calamares-finished.png")
    for label in ("Restart", "Done", "Finish", "Quit"):
        try:
            gui.click_word(label, lower_right=True)
            return False
        except RuntimeError:
            continue
    raise RuntimeError(f"No completion button found: {gui.last_text[:1200]}")


def first_plasma_login(gui):
    gui.wait_text(["Password", "Log In", "Login"], 900, "installed SDDM login")
    # SDDM selects the only newly-created account on a clean install.
    gui.type_text("veyra-ci-password")
    gui.key("Return")
    time.sleep(30)
    gui.key("ctrl+alt+t")
    gui.wait_text(["Konsole"], 180, "Konsole in installed Plasma session")
    gui.type_text("printf 'VEYRA_PLASMA_LOGIN_OK\\n'")
    gui.key("Return")
    gui.wait_text(["VEYRA_PLASMA_LOGIN_OK"], 45, "interactive command in Plasma")
    gui.screenshot("plasma-first-login.png")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("iso", type=pathlib.Path)
    parser.add_argument("--output-dir", type=pathlib.Path, default=pathlib.Path("calamares-gui-e2e"))
    parser.add_argument("--launch-only", action="store_true",
                        help="boot the Live desktop and verify the installer welcome page")
    parser.add_argument("--autostart-diagnostic", action="store_true",
                        help="expect Calamares to launch from a diagnostic-only ISO autostart")
    args = parser.parse_args()
    if not args.iso.is_file():
        parser.error("ISO file does not exist")
    if not os.environ.get("DISPLAY"):
        parser.error("Run under Xvfb (for example, xvfb-run -a ...)")
    require_tools(parser)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    qemu = shutil.which("qemu-system-x86_64")
    qimg = shutil.which("qemu-img")
    with tempfile.TemporaryDirectory(prefix="veyra-calamares-gui-") as temp:
        disk = pathlib.Path(temp) / "install-disk.qcow2"
        subprocess.run([qimg, "create", "-f", "qcow2", str(disk), "32G"], check=True)
        live_log_path = args.output_dir / "live-serial.log"
        process, log = boot(qemu, disk, live_log_path, args.iso.resolve())
        try:
            gui = Gui(wait_window("veyra-calamares-e2e", process), args.output_dir, "live")
            if args.autostart_diagnostic:
                gui.wait_text(["Welcome", "Location"], 900,
                              "Calamares welcome page from diagnostic autostart")
                launch_method = "diagnostic-autostart"
            else:
                launch_method = launch_calamares(gui)
            if args.launch_only:
                print(f"VEYRA_CALAMARES_LAUNCH_OK method={launch_method}", flush=True)
                return
            early_close = install_via_gui(gui)
            if early_close:
                stop(process, log)
                process, log = None, None
            else:
                try:
                    process.wait(timeout=180)
                except subprocess.TimeoutExpired:
                    gui.key("ctrl+alt+delete")
                    process.wait(timeout=60)
        finally:
            if process is not None:
                stop(process, log)

        installed_log_path = args.output_dir / "installed-serial.log"
        process, log = boot(qemu, disk, installed_log_path)
        try:
            gui = Gui(wait_window("veyra-calamares-e2e", process), args.output_dir, "installed")
            first_plasma_login(gui)
            print("VEYRA_INSTALLED_PLASMA_LOGIN_OK", flush=True)
        finally:
            stop(process, log)
        if early_close:
            raise RuntimeError(
                "The installed system booted and Plasma login worked, but "
                "Calamares closed before showing its completion page."
            )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"VEYRA_CALAMARES_GUI_TEST_FAILED: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
