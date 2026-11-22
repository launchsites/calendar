"""Private, per-account storage for complete calendar snapshots."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import closing, contextmanager
from dataclasses import replace
from datetime import timezone
from hashlib import sha256
import os
from pathlib import Path
import sqlite3

import icalendar

from caldav_store import Calendar, CalendarError, event_times, is_recurring, occurrences


SCHEMA = """
CREATE TABLE IF NOT EXISTS calendars (
    url TEXT PRIMARY KEY, title TEXT NOT NULL, color TEXT NOT NULL,
    writable INTEGER NOT NULL, revision TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS resources (
    calendar TEXT NOT NULL REFERENCES calendars(url) ON DELETE CASCADE,
    href TEXT NOT NULL, etag TEXT NOT NULL, raw BLOB NOT NULL, starts REAL, ends REAL,
    PRIMARY KEY (calendar, href)
);
CREATE INDEX IF NOT EXISTS resources_by_end ON resources(calendar, ends);
"""


def cache_directory():
    configured = Path(os.environ.get("XDG_CACHE_HOME", ""))
    root = configured if configured.is_absolute() else Path.home() / ".cache"
    return root / "stillday"


def bounds(raw):
    try:
        components = icalendar.Calendar.from_ical(raw).walk("VEVENT")
        if not is_recurring(components):
            begins, ends, _ = event_times(components[0], timezone.utc)
            return begins.timestamp(), ends.timestamp()
    except (ValueError, TypeError, KeyError, OverflowError):
        pass
    # Series can have exceptions and unbounded recurrence. Expand them only for the requested view.
    return None, None


class CalendarCache:
    def __init__(self, username, directory=None):
        account = sha256(username.strip().casefold().encode()).hexdigest()
        self.path = (directory if directory is not None else cache_directory()) / f"{account}.sqlite3"

    @contextmanager
    def _write(self):
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.close(os.open(self.path, os.O_CREAT | os.O_WRONLY, 0o600))
        with closing(sqlite3.connect(self.path)) as db:
            db.execute("PRAGMA foreign_keys = ON")
            db.executescript(SCHEMA)
            with db:
                yield db

    def catalog(self):
        if not self.path.is_file():
            return {}
        try:
            with closing(sqlite3.connect(self.path, timeout=0.1)) as db:
                return {url: Calendar(url, title, color, bool(writable), revision)
                        for url, title, color, writable, revision in db.execute(
                            "SELECT url, title, color, writable, revision FROM calendars"
                        )}
        except (OSError, sqlite3.Error):
            return {}

    def events(self, calendar, start, end, zone):
        # Floating and all-day dates were indexed as UTC wall time, so allow for time-zone shifts.
        margin = 2 * 86400
        with closing(sqlite3.connect(self.path)) as db:
            rows = db.execute(
                """SELECT href, etag, raw FROM resources WHERE calendar = ? AND ends IS NULL
                   UNION ALL
                   SELECT href, etag, raw FROM resources WHERE calendar = ? AND ends >= ? AND starts < ?""",
                (calendar.url, calendar.url, start.timestamp() - margin, end.timestamp() + margin),
            ).fetchall()
        events = {}
        for href, etag, raw in rows:
            try:
                for item in occurrences(calendar, href, etag, raw, start, end, zone):
                    events[item.key] = item
            except (ValueError, TypeError, KeyError, OverflowError):
                continue
        return list(events.values())

    def sync(self, store, calendars, stopping):
        saved = self.catalog()

        def update(calendar):
            if stopping.is_set():
                return False
            previous = saved.get(calendar.url)
            try:
                if not calendar.revision:
                    try:
                        calendar = replace(calendar, revision=store.resource_revision(calendar))
                    except CalendarError:
                        pass
                changed = not (previous and calendar.revision and previous.revision == calendar.revision)
                rows = [(calendar.url, href, tag, raw, *bounds(raw))
                        for href, tag, raw in store.event_resources(calendar)] if changed else None
                if stopping.is_set():
                    return False
                if changed or previous != calendar:
                    with self._write() as db:
                        db.execute(
                            """INSERT INTO calendars VALUES (?, ?, ?, ?, ?) ON CONFLICT(url) DO UPDATE SET
                               title=excluded.title, color=excluded.color, writable=excluded.writable,
                               revision=excluded.revision""",
                            (calendar.url, calendar.title, calendar.color, calendar.writable, calendar.revision),
                        )
                        if changed:
                            db.execute("DELETE FROM resources WHERE calendar = ?", (calendar.url,))
                            db.executemany("INSERT OR REPLACE INTO resources VALUES (?, ?, ?, ?, ?, ?)", rows)
                return True
            except (CalendarError, OSError, sqlite3.Error):
                return False

        with ThreadPoolExecutor(max_workers=2) as workers:
            synced = set(calendar.url for calendar, ok in zip(calendars, workers.map(update, calendars)) if ok)
        if not stopping.is_set():
            removed = set(saved) - {calendar.url for calendar in calendars}
            if removed:
                with self._write() as db:
                    db.executemany("DELETE FROM calendars WHERE url = ?", [(url,) for url in removed])
        return set(self.catalog()), synced
