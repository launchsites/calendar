"""Linux desktop launcher and installed revision metadata."""

import os
from pathlib import Path
import re
import struct
import subprocess
import sys


APP_ID = "com.example.stillday.calendar"
ROOT = Path(__file__).resolve().parents[1]
REVISION = re.compile(r"[0-9a-f]{40}")


def data_home():
    value = os.environ.get("XDG_DATA_HOME", "")
    path = Path(value)
    return path if path.is_absolute() else Path.home() / ".local/share"


def icon_png(root=ROOT):
    """Read the PNG representation of the existing Calendar icon."""
    raw = (root / "Resources/Stillday.icns").read_bytes()
    if not raw.startswith(b"icns"):
        raise ValueError("Invalid Calendar app icon")
    offset = 8
    while offset + 8 <= len(raw):
        kind, size = struct.unpack_from(">4sI", raw, offset)
        if size < 8 or offset + size > len(raw):
            break
        payload = raw[offset + 8:offset + size]
        if kind == b"ic10" and payload.startswith(b"\x89PNG\r\n\x1a\n"):
            return payload
        offset += size
    raise ValueError("Calendar app icon has no PNG representation")


def source_revision(root):
    try:
        # A downloaded source tree may sit inside an unrelated repository.
        top = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=root,
                                      stderr=subprocess.DEVNULL, text=True, timeout=5).strip()
        if Path(top).resolve() == root.resolve():
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root,
                                             stderr=subprocess.DEVNULL, text=True, timeout=5).strip()
            if REVISION.fullmatch(commit):
                return commit
    except (OSError, subprocess.SubprocessError):
        pass
    path = root / "Linux/source-revision"
    value = path.read_text(encoding="utf-8").strip() if path.exists() else ""
    return value if REVISION.fullmatch(value) else ""


def installed_revision(root=ROOT):
    path = root / ".build/linux-installed-revision"
    value = path.read_text(encoding="utf-8").strip() if path.exists() else ""
    return value if REVISION.fullmatch(value) else ""


def write_atomic(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_bytes(content)
    temporary.replace(path)


def exec_argument(path):
    value = str(path)
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("Install Calendar from a folder whose path contains no control characters.")
    escaped = value.replace("%", "%%")
    for char in ('\\', '"', '`', '$'):
        escaped = escaped.replace(char, "\\" + char)
    return '"' + escaped.replace("\\", "\\\\") + '"'


def install(root=ROOT, home=None):
    home = home or data_home()
    write_atomic(home / f"icons/hicolor/1024x1024/apps/{APP_ID}.png", icon_png(root))
    desktop = (
        "[Desktop Entry]\nType=Application\nName=Calendar\n"
        "Comment=View and edit your calendars\n"
        f"Exec={exec_argument(root / 'Scripts/run-linux')}\n"
        f"Icon={APP_ID}\nStartupWMClass={APP_ID}\n"
        "Terminal=false\nCategories=Office;Calendar;\n"
    )
    write_atomic(home / f"applications/{APP_ID}.desktop", desktop.encode())
    write_atomic(root / ".build/linux-installed-revision", (source_revision(root) + "\n").encode())


if __name__ == "__main__":
    try:
        install()
    except (OSError, ValueError) as error:
        sys.exit(str(error))
