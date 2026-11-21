"""Explicit updates from Calendar's public main branch."""

from pathlib import Path
import subprocess

import requests

from caldav_store import CalendarError
from calendar_install import REVISION, ROOT, data_home, installed_revision


REPO = "https://github.com/launchsites/calendar.git"
HEAD = "https://api.github.com/repos/launchsites/calendar/commits/main"


def latest_revision():
    try:
        response = requests.get(HEAD, headers={"Accept": "application/vnd.github+json"}, timeout=10)
        response.raise_for_status()
        revision = response.json().get("sha", "")
        if not isinstance(revision, str) or not REVISION.fullmatch(revision):
            raise ValueError
        return revision
    except (requests.RequestException, AttributeError, ValueError):
        raise CalendarError("Couldn’t check GitHub for updates. Try again later.") from None


def git(root, *args, timeout=30):
    return subprocess.run(["git", *args], cwd=root, capture_output=True, text=True,
                          timeout=timeout, check=True).stdout.strip()


def own_checkout(root):
    if not (root / ".git").exists():
        return False
    return Path(git(root, "rev-parse", "--show-toplevel")).resolve() == root.resolve()


def install_update(revision, root=ROOT):
    """Advance a clean checkout, or install a Git checkout for a source archive."""
    if not REVISION.fullmatch(revision):
        raise CalendarError("GitHub returned an invalid version.")
    try:
        target = root
        if not own_checkout(root):
            target = data_home() / "Calendar/source"
            if not target.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                git(target.parent, "clone", "--single-branch", "--branch", "main", REPO, str(target))
        if not own_checkout(target) or git(target, "branch", "--show-current") != "main":
            raise CalendarError("Updates require a Calendar checkout on the main branch.")
        if git(target, "status", "--porcelain"):
            raise CalendarError("Your Calendar checkout has local changes. Save them before updating.")
        git(target, "fetch", "--no-tags", REPO, "refs/heads/main")
        if git(target, "rev-parse", "FETCH_HEAD") != revision:
            raise CalendarError("GitHub has a newer version now. Check again before updating.")
        try:
            git(target, "merge-base", "--is-ancestor", "HEAD", revision)
        except subprocess.CalledProcessError:
            raise CalendarError("This checkout has local commits. Update it manually.") from None
        git(target, "merge", "--ff-only", revision)
    except (OSError, subprocess.SubprocessError):
        raise CalendarError("Couldn’t download the update. Check Git and your connection, then try again.") from None

    try:
        subprocess.run(["bash", str(target / "Scripts/setup-linux")], cwd=target,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=900, check=True)
        if installed_revision(target) != revision:
            raise CalendarError("The update was downloaded, but its install could not be verified.")
    except (OSError, subprocess.SubprocessError):
        raise CalendarError("The update was downloaded, but setup failed. Run Scripts/setup-linux to see the error.") from None
    return target / "Scripts/run-linux"
