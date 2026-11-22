"""Learn destinations from previous events using the shared Calendar engine."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, time, timedelta
from hashlib import sha256
import json

from caldav_store import CalendarError


class CalendarHistory:
    def __init__(self, owner):
        self.owner = owner
        self.key = None
        self.data = None
        self.seeded = False
        self.seeding = False
        self.pending = []

    def open(self, account, *, start_import=True):
        digest = sha256(account.strip().casefold().encode("utf-8")).hexdigest()
        self.key = "calendarHistory/" + digest
        try:
            saved = json.loads(self.owner.settings.value(self.key, "{}", str))
            self.data = saved.get("usage")
            self.seeded = saved.get("seeded", False)
        except (ValueError, AttributeError):
            self.data, self.seeded = None, False
        self.seeding = False
        self.pending = []
        if start_import:
            self.seed()

    def seed(self):
        owner = self.owner
        if (not self.key or self.seeded or self.seeding or owner.reading or owner.jobs.stopping.is_set()
                or not owner.preferences.suggest_calendars):
            return
        calendars = [calendar for calendar in owner.calendars if calendar.writable]
        if not calendars or not owner.store:
            return
        store, key = owner.store, self.key
        cache, cached = owner.cache, owner.cached_urls
        core, stopping = owner.core, owner.jobs.stopping
        end = owner.now()
        start = end - timedelta(days=180)
        self.seeding = True

        def load(calendar):
            if stopping.is_set():
                return []
            source = cache if calendar.url in cached else store
            return source.events(calendar, start, end, end.tzinfo)

        def read():
            with ThreadPoolExecutor(max_workers=2) as workers:
                events = [event for batch in workers.map(load, calendars) for event in batch
                          if not event.recurring and event.start.timestamp() < end.timestamp()]
            if stopping.is_set():
                return None
            records = [(event.title, event.calendar.url, event.start.timestamp())
                       for event in sorted(events, key=lambda entry: (entry.start.timestamp(), entry.key))][-10000:]
            usage = core.call("learnCalendars", choices=[{"title": title, "calendarID": calendar}
                                                        for title, calendar, _ in records])
            return usage, set(records)

        def complete(result, error):
            if key != self.key or store is not owner.store:
                return
            self.seeding = False
            pending, self.pending = self.pending, []
            if not error and result is not None:
                self.data, seen = result
                self.seeded = True
                pending = [item for item in pending if item not in seen]
            if pending:
                self.learn(pending)
            if self.seeded or pending:
                self.save()
            owner.history_changed.emit()

        owner.work(read, complete)

    def record(self, title, calendar, start):
        if not self.key or not self.owner.preferences.suggest_calendars:
            return
        if hasattr(start, "timestamp"):
            stamp = start.timestamp()
        else:
            stamp = datetime.combine(start, time.min, self.owner.now().tzinfo).timestamp()
        item = (title, calendar.url, stamp)
        if self.seeding:
            self.pending.append(item)
        elif self.learn([item]):
            self.save()
            self.owner.history_changed.emit()

    def learn(self, records):
        try:
            self.data = self.owner.core.call(
                "learnCalendars", usage=self.data,
                choices=[{"title": title, "calendarID": calendar} for title, calendar, _ in records],
            )
            return True
        except CalendarError:
            return False

    def save(self):
        self.owner.settings.setValue(self.key, json.dumps({"usage": self.data, "seeded": self.seeded}))

    def suggest(self, title, calendars, requested, *, use_history=True):
        prefs = self.owner.preferences
        return self.owner.core.call(
            "suggestCalendar", text=title, requestedCalendar=requested,
            preferredCalendar=prefs.default_calendar or None,
            calendars=[{"id": calendar.url, "title": calendar.title} for calendar in calendars],
            usage=self.data if prefs.suggest_calendars and use_history else None,
        )
