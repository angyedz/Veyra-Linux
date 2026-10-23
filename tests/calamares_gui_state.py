"""Small OCR text classifiers shared by the Calamares GUI test and CI."""


_INSTALLER_PAGE_MARKERS = (
    "veyra linux installer",
    "continue with installation",
    "install now",
    "install boot loader",
    "unpartitioned space or unknown partition",
    "set timezone to",
)


def is_live_desktop(text):
    """Return true only when OCR sees the live desktop's installer shortcut."""
    normalized = " ".join(text.casefold().split())
    return (
        "install veyra linux" in normalized
        and not any(marker in normalized for marker in _INSTALLER_PAGE_MARKERS)
    )
