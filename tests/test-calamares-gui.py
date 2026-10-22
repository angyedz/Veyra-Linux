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


class Gui:
    def __init__(self, window, output_dir, label):
        self.window = window
        self.output_dir = output_dir
        self.label = label
        self.serial_log_path = output_dir / f"{label}-serial.log"
        self.last_text = ""

    def command(self, *args, check=True, timeout=30):
        result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
        if check and result.returncode:
            raise RuntimeError(
                f"Command failed ({result.returncode}): {' '.join(args)}\n"
                f"{result.stdout}\n{result.stderr}"
            )
        return result

    def screenshot(self, name=None):
        path = self.output_dir / (name or f"{self.label}-screen.png")
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
            time.sleep(2)
        raise RuntimeError(
            f"Timed out waiting for {description}; last visible text: {self.last_text[:1200]}"
        )

    def click_word(self, label, lower_right=False, double=False):
        text, boxes = self.screenshot()
        matches = [box for box in boxes if box[0].lower().strip(".,:;!?") == label.lower()]
        if lower_right:
            matches = [box for box in matches if box[1] >= 0.55 * 900 and box[2] >= 0.65 * 600]
        if not matches:
            raise RuntimeError(f"Could not find {label!r}; visible text: {text[:1200]}")
        word, x, y, width, height = sorted(matches, key=lambda box: (box[2], box[1]))[-1]
        self.focus()
        self.command("xdotool", "mousemove", "--window", str(self.window),
                     str(x + max(width // 2, 1)), str(y + max(height // 2, 1)))
        if double:
            self.command("xdotool", "click", "--repeat", "2", "--delay", "250", "1")
        else:
            self.command("xdotool", "click", "1")
        time.sleep(2)
        print(f"{self.label}: clicked {word!r} at {x},{y}", flush=True)

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
        qemu, "-name", "veyra-calamares-e2e", "-machine", "accel=tcg",
        "-m", "6144", "-smp", "4", "-vga", "virtio", "-display", "sdl",
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
    gui.key("alt+F2")
    time.sleep(2)
    gui.type_text("veyra-install")
    gui.key("Return")
    gui.wait_text(["Welcome", "Location"], 180, "Calamares welcome page")


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
    gui.click_word("Install", lower_right=True)
    deadline = time.monotonic() + 3300
    confirmation_handled = False
    completion_terms = ("restart", "finished", "all done", "installation complete")
    while time.monotonic() < deadline:
        text, _ = gui.screenshot()
        lowered = text.lower()
        if any(term in lowered for term in completion_terms):
            break
        if (not confirmation_handled and
                ("are you sure" in lowered or "confirm" in lowered)):
            gui.click_word("Install", lower_right=True)
            confirmation_handled = True
        time.sleep(5)
    else:
        raise RuntimeError(f"Timed out waiting for installation completion: {gui.last_text[:1200]}")
    gui.screenshot("calamares-finished.png")
    for label in ("Restart", "Done", "Finish", "Quit"):
        try:
            gui.click_word(label, lower_right=True)
            return
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
            launch_calamares(gui)
            install_via_gui(gui)
            try:
                process.wait(timeout=180)
            except subprocess.TimeoutExpired:
                gui.key("ctrl+alt+delete")
                process.wait(timeout=60)
        finally:
            stop(process, log)

        installed_log_path = args.output_dir / "installed-serial.log"
        process, log = boot(qemu, disk, installed_log_path)
        try:
            gui = Gui(wait_window("veyra-calamares-e2e", process), args.output_dir, "installed")
            first_plasma_login(gui)
            print("VEYRA_CALAMARES_GUI_INSTALL_AND_PLASMA_LOGIN_OK", flush=True)
        finally:
            stop(process, log)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"VEYRA_CALAMARES_GUI_TEST_FAILED: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
