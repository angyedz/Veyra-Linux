#!/usr/bin/env python3
"""Keep desktop detection distinct from the Calamares timezone notification."""

from calamares_gui_state import is_live_desktop


desktop_ocr = """
Install Veyra
Linux
Time zone is not set; click here to open Date & Time settings
"""
summary_ocr = """
Veyra Linux Installer
Location Keyboard Partitions Users Summary
Continue with Installation?
Install Now | Go Back
Install Veyra on new ext4 system partition
"""
welcome_ocr = """
Welcome to the Veyra Linux Development Installer
"""

assert is_live_desktop(desktop_ocr)
assert not is_live_desktop(summary_ocr)
assert not is_live_desktop(welcome_ocr)
print("Calamares GUI screen-state classification passed")
