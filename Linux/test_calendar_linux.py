"""Disposable CalDAV fixtures and desktop smoke coverage."""

import os
import sys
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Event as Gate, Lock
from time import monotonic
import unittest
from unittest.mock import Mock, patch

import icalendar
import requests

from caldav_store import Calendar, CalendarError, Draft, ICloudStore, cloud_url, occurrences
from calendar_cache import CalendarCache


ZONE = timezone.utc
CAL = Calendar("https://p10-caldav.icloud.com/1/calendars/work/", "Work", "#5489df", True)
HREF = CAL.url + "event.ics"
START = datetime(2026, 11, 21, 10, tzinfo=ZONE)
END = datetime(2026, 11, 21, 11, tzinfo=ZONE)
DATA = (
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Fixture//EN\r\nBEGIN:VEVENT\r\n"
    "UID:fixture\r\nDTSTAMP:20261121T090000Z\r\nDTSTART:20261121T100000Z\r\n"
    "DTEND:20261121T110000Z\r\nSUMMARY:Original\r\nLOCATION:Workshop\r\n"
    "X-EXTRA:Keep this\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
).encode()


class StoreTests(unittest.TestCase):
    def test_discover_calendars_and_permissions(self):
        responses = [
            '<d:current-user-principal><d:href>/1/principal/</d:href></d:current-user-principal>',
            '<c:calendar-home-set><d:href>/1/calendars/</d:href></c:calendar-home-set>',
            '<d:displayname>Work</d:displayname><a:calendar-color>#5489dfFF</a:calendar-color>'
            '<d:sync-token>fixture-version</d:sync-token>'
            '<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>'
            '<d:current-user-privilege-set><d:privilege><d:read/></d:privilege></d:current-user-privilege-set>',
        ]

        def request(method, url, body=None, headers=None):
            response = requests.Response()
            response.url = "https://p10-caldav.icloud.com/"
            response._content = ('<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" '
                                 'xmlns:a="http://apple.com/ns/ical/"><d:response>'
                                 '<d:href>/1/calendars/work/</d:href><d:propstat><d:prop>' +
                                 responses.pop(0) + '</d:prop><d:status>HTTP/1.1 200 OK</d:status>'
                                 '</d:propstat></d:response></d:multistatus>').encode()
            return response

        store = ICloudStore("demo@example.invalid", "fixture")
        with patch.object(store, "request", side_effect=request):
            found, = store.discover()
            self.assertEqual(found, Calendar(CAL.url, "Work", "#5489df", False))
            self.assertEqual(found.revision, "sync:fixture-version")

    def test_resource_revision_checks_membership_and_is_independent_of_order(self):
        from defusedxml import ElementTree as XML

        store = ICloudStore("demo@example.invalid", "fixture")
        first = (HREF, {"{DAV:}getetag": XML.fromstring('<d:getetag xmlns:d="DAV:">"one"</d:getetag>')})
        second = (CAL.url + "another.ics", first[1])
        with patch.object(store, "query", side_effect=[(CAL.url, [first, second]),
                                                      (CAL.url, [second, first]), (CAL.url, [first])]):
            revision = store.resource_revision(CAL)
            self.assertTrue(revision.startswith("etag:"))
            self.assertEqual(revision, store.resource_revision(CAL))
            self.assertNotEqual(revision, store.resource_revision(CAL))

    def test_redirect_never_sends_credentials_to_another_site(self):
        response = requests.Response()
        response.status_code = 302
        response.headers["Location"] = "https://caldav.icloud.com.example.invalid/"
        store = ICloudStore("demo@example.invalid", "fixture")
        with patch("caldav_store.requests.request", return_value=response) as request:
            with self.assertRaises(CalendarError):
                store.request("PROPFIND", CAL.url)
            self.assertEqual(request.call_count, 1)
        with self.assertRaises(CalendarError):
            cloud_url(CAL.url, "http://caldav.icloud.com/")

    def test_edit_keeps_existing_data_and_uses_the_opened_version(self):
        event, = occurrences(CAL, HREF, '"first"', DATA, START, END, ZONE)
        store = ICloudStore("demo@example.invalid", "fixture")
        with patch.object(store, "request") as request:
            store.save(CAL, Draft("Updated", START, END, "Description"), event)
            method, href, body, headers = request.call_args.args
            self.assertEqual((method, href, headers["If-Match"]), ("PUT", HREF, '"first"'))
            edited, = icalendar.Calendar.from_ical(body).walk("VEVENT")
            self.assertEqual(edited.decoded("DTSTART"), START)
            self.assertEqual(str(edited["SUMMARY"]), "Updated")
            self.assertEqual(str(edited["DESCRIPTION"]), "Description")
            self.assertEqual(str(edited["LOCATION"]), "Workshop")
            self.assertEqual(str(edited["X-EXTRA"]), "Keep this")
            store.delete(event)
            request.assert_called_with("DELETE", HREF, headers={"If-Match": '"first"'})

    def test_recurring_event_expands_but_cannot_be_overwritten(self):
        recurring = DATA.replace(b"END:VEVENT", b"RRULE:FREQ=DAILY;COUNT=2\r\nEND:VEVENT")
        stop = END.replace(day=23)
        events = list(occurrences(CAL, HREF, '"first"', recurring, START, stop, ZONE))
        self.assertEqual([event.start.day for event in events], [21, 22])
        self.assertTrue(all(not event.editable for event in events))

    def test_resize_preserves_unmoved_time_metadata_and_checks_version(self):
        event, = occurrences(CAL, HREF, '"first"', DATA, START, END, ZONE)
        store = ICloudStore("demo@example.invalid", "fixture")
        with patch.object(store, "request") as request:
            new_end = END.replace(minute=15)
            store.resize(event, START, new_end)
            method, href, body, headers = request.call_args.args
            self.assertEqual((method, href, headers["If-Match"]), ("PUT", HREF, '"first"'))
            edited, = icalendar.Calendar.from_ical(body).walk("VEVENT")
            self.assertEqual(edited.decoded("DTSTART"), START)
            self.assertEqual(edited.decoded("DTEND"), new_end)
            self.assertEqual(str(edited["LOCATION"]), "Workshop")
            self.assertEqual(str(edited["X-EXTRA"]), "Keep this")

    def test_stale_write_has_a_user_facing_error(self):
        response = requests.Response()
        response.status_code = 412
        with patch("caldav_store.requests.request", return_value=response):
            with self.assertRaisesRegex(CalendarError, "changed on another device"):
                ICloudStore("demo@example.invalid", "fixture").request("PUT", HREF)


    def test_shutdown_cancels_reads_before_request_or_redirect(self):
        stop = Gate()
        store = ICloudStore("demo@example.invalid", "fixture", stop_reads=stop)
        with patch("caldav_store.requests.request") as request:
            stop.set()
            with self.assertRaisesRegex(CalendarError, "loading was cancelled"):
                store.discover()
            request.assert_not_called()
            stop.clear()

            def redirect(*args, **kwargs):
                response = requests.Response()
                response.status_code = 301
                response.headers["Location"] = CAL.url
                stop.set()
                return response

            request.side_effect = redirect
            with self.assertRaisesRegex(CalendarError, "loading was cancelled"):
                store.events(CAL, START, END, ZONE)
            self.assertEqual(request.call_count, 1)


class CacheTests(unittest.TestCase):
    def test_cached_one_off_event_reuses_decode_and_refreshes_changed_body(self):
        with TemporaryDirectory() as folder:
            cache = CalendarCache("demo@example.invalid", Path(folder))
            store = Mock(spec=ICloudStore)
            initial = replace(CAL, revision="sync:1")
            store.event_resources.return_value = [(HREF, '"first"', DATA)]
            cache.sync(store, [initial], Gate())
            first, = cache.events(initial, START, END, ZONE)
            repeated, = cache.events(initial, START - timedelta(hours=1), END, ZONE)
            self.assertIs(first, repeated)
            changed = replace(CAL, revision="sync:2")
            store.event_resources.return_value = [(HREF, '"first"', DATA.replace(b"Original", b"Updated"))]
            cache.sync(store, [changed], Gate())
            fresh, = cache.events(changed, START, END, ZONE)
            self.assertEqual(fresh.title, "Updated")
            self.assertEqual(fresh.raw, DATA.replace(b"Original", b"Updated"))

    def test_complete_snapshots_skip_unchanged_data_and_keep_last_good_copy(self):
        with TemporaryDirectory() as folder:
            cache = CalendarCache("demo@example.invalid", Path(folder) / "cache")
            stopping = Gate()
            store = Mock(spec=ICloudStore)
            initial = replace(CAL, revision="sync:1")
            recurring = DATA.replace(b"END:VEVENT", b"RRULE:FREQ=DAILY\r\nEND:VEVENT")
            store.event_resources.return_value = [(HREF, '"first"', recurring)]
            self.assertEqual(cache.sync(store, [initial], stopping), ({CAL.url}, {CAL.url}))
            self.assertEqual(cache.path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(cache.path.parent.stat().st_mode & 0o777, 0o700)
            restored = CalendarCache("DEMO@example.invalid", cache.path.parent)
            future = START + timedelta(days=90)
            event, = restored.events(initial, future, future + timedelta(hours=2), ZONE)
            self.assertEqual((event.title, event.start, event.etag), ("Original", future, '"first"'))
            self.assertEqual(CalendarCache("other@example.invalid", cache.path.parent).catalog(), {})
            self.assertEqual(cache.sync(store, [initial], stopping), ({CAL.url}, {CAL.url}))
            store.event_resources.assert_called_once_with(initial)

            def incomplete(calendar):
                yield HREF, '"new"', DATA
                raise CalendarError("Incomplete response")

            updated = replace(CAL, revision="sync:2")
            store.event_resources.side_effect = incomplete
            self.assertEqual(cache.sync(store, [updated], stopping), ({CAL.url}, set()))
            self.assertEqual(restored.catalog()[CAL.url].revision, "sync:1")
            self.assertEqual(restored.events(initial, future, future + timedelta(hours=2), ZONE)[0].etag, '"first"')
            store.event_resources.side_effect = None
            store.event_resources.return_value = []
            self.assertEqual(cache.sync(store, [updated], stopping), ({CAL.url}, {CAL.url}))
            self.assertEqual(restored.events(updated, START, END, ZONE), [])
            self.assertEqual(cache.sync(store, [], stopping), (set(), set()))


class InstallTests(unittest.TestCase):
    def test_desktop_identity_uses_the_calendar_icon_and_installed_revision(self):
        from pathlib import Path
        from tempfile import TemporaryDirectory
        from PySide6.QtGui import QImage
        from calendar_install import APP_ID, ROOT, icon_file, install, installed_revision

        with TemporaryDirectory() as folder:
            root = Path(folder) / 'Sample % calendar'
            (root / "Resources").mkdir(parents=True)
            (root / "Linux").mkdir()
            (root / "Resources/Stillday.icns").write_bytes((ROOT / "Resources/Stillday.icns").read_bytes())
            (root / "Linux/source-revision").write_text("a" * 40)
            home = Path(folder) / "data"
            install(root, home)
            launcher = (home / f"applications/{APP_ID}.desktop").read_text()
            self.assertIn("Name=Calendar\n", launcher)
            self.assertIn(f"StartupWMClass={APP_ID}\n", launcher)
            self.assertIn("Sample %% calendar/Scripts/run-linux", launcher)
            for size in (256, 512):
                image = QImage(str(icon_file(home, size)))
                self.assertEqual((image.width(), image.height()), (size, size))
            self.assertIn(f"Icon={icon_file(home, 512)}\n", launcher)
            self.assertFalse(icon_file(home, 1024).exists())
            self.assertEqual(installed_revision(root), "a" * 40)

    def test_clean_checkout_fast_forwards_and_dirty_checkout_is_preserved(self):
        from pathlib import Path
        from tempfile import TemporaryDirectory
        from calendar_update import git, install_update

        with TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "source"
            source.mkdir()
            git(source, "init", "-b", "main")
            git(source, "config", "user.name", "Fixture")
            git(source, "config", "user.email", "demo@example.invalid")
            (source / "Scripts").mkdir()
            (source / ".gitignore").write_text(".build/\n")
            (source / "Scripts/setup-linux").write_text(
                "#!/bin/sh\nmkdir -p .build\ngit rev-parse HEAD > .build/linux-installed-revision\n"
            )
            git(source, "add", ".gitignore", "Scripts")
            git(source, "commit", "-m", "Initial")
            git(root, "clone", str(source), "checkout")
            checkout = root / "checkout"
            first = git(checkout, "rev-parse", "HEAD")
            (source / "version").write_text("new")
            git(source, "add", "version")
            git(source, "commit", "-m", "Update")
            revision = git(source, "rev-parse", "HEAD")
            with patch("calendar_update.REPO", str(source)):
                dirty = checkout / "local-changes"
                dirty.write_text("keep")
                with self.assertRaisesRegex(CalendarError, "local changes"):
                    install_update(revision, checkout)
                self.assertEqual(git(checkout, "rev-parse", "HEAD"), first)
                dirty.unlink()
                self.assertEqual(install_update(revision, checkout), checkout / "Scripts/run-linux")
            self.assertEqual(git(checkout, "rev-parse", "HEAD"), revision)


def wait_for(condition, timeout=5):
    from PySide6.QtTest import QTest

    deadline = monotonic() + timeout
    while not condition() and monotonic() < deadline:
        QTest.qWait(15)
    return condition()


class SlowCalendarStore:
    def __init__(self, stop_reads):
        self.stop_reads = stop_reads
        self.discovery = Gate()
        self.history = Gate()
        self.visible = Gate()
        self.early = Gate()
        self.lock = Lock()
        self.active = {"discovery": 0, "visible": 0, "history": 0}
        self.calendars = [
            Calendar(f"https://caldav.icloud.com/fixture-{i}/", f"Calendar {i}", "#4180b9", True)
            for i in range(15)
        ]

    def busy(self, name):
        with self.lock:
            return self.active[name] > 0

    def wait(self, gate, name):
        with self.lock:
            self.active[name] += 1
        try:
            # Simulate an HTTP request already on the wire when the window closes.
            return gate.wait(5) and not self.stop_reads.is_set()
        finally:
            with self.lock:
                self.active[name] -= 1

    def discover(self):
        self.wait(self.discovery, "discovery")
        return self.calendars

    def resource_revision(self, calendar):
        return "fixture"

    def event_resources(self, calendar):
        self.wait(self.history, "history")
        return []

    def events(self, calendar, start, end, zone):
        historical = (end - start).days >= 100
        gate, name = (self.history, "history") if historical else (self.visible, "visible")
        if not historical and calendar is self.calendars[0] and self.early.is_set():
            gate = self.early
        if not self.wait(gate, name):
            return []
        from caldav_store import Event

        count = 2 if calendar is self.calendars[-2] else 4
        stamp = datetime.combine(START.date(), START.time(), zone)
        if historical:
            stamp -= timedelta(days=10)
        return [Event(f"{calendar.url}{index}", calendar, "", "", f"Fixture event {index}",
                      stamp + timedelta(hours=index), stamp + timedelta(hours=index + 1),
                      False, "", b"", False) for index in range(count)]


@unittest.skipUnless(os.environ.get("CALENDAR_CORE_TEST_BIN"), "requires the built Swift helper")
class DesktopTests(unittest.TestCase):
    def fixture_window(self, file):
        from PySide6 import QtCore, QtWidgets
        from calendar_app import CalendarWindow, Core, ZONE

        app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
        prefs = QtCore.QSettings(str(file), QtCore.QSettings.Format.IniFormat)
        window = CalendarWindow(Core(os.environ["CALENDAR_CORE_TEST_BIN"]),
                                clock=lambda: datetime(2026, 11, 21, 13, tzinfo=ZONE), settings=prefs)
        window.show()
        return app, window

    def interact_during_load(self, window):
        from PySide6 import QtCore, QtTest, QtWidgets

        for button in (window.views.button(id) for id in (1, 2, 3, 1, 2)):
            QtTest.QTest.mouseClick(button, QtCore.Qt.MouseButton.LeftButton)
            QtTest.QTest.qWait(5)

        def close_popup():
            for menu in window.findChildren(QtWidgets.QMenu):
                if menu.isVisible():
                    menu.close()

        def close_dialog():
            modal = QtWidgets.QApplication.activeModalWidget()
            if modal:
                modal.reject()

        QtCore.QTimer.singleShot(30, close_popup)
        window.open_menu()
        QtCore.QTimer.singleShot(30, close_dialog)
        window.open_settings()

    def test_close_window_during_account_discovery(self):
        from pathlib import Path
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as folder:
            app, window = self.fixture_window(Path(folder) / "discovery.ini")
            store = SlowCalendarStore(window.jobs.stopping)
            try:
                with patch("calendar_app.ICloudStore", return_value=store):
                    window.connect_account("demo@example.invalid", "fixture", remember=False)
                self.assertTrue(wait_for(lambda: store.busy("discovery")))
                self.interact_during_load(window)
                self.assertTrue(store.busy("discovery"))
                window.close()
                self.assertFalse(window.isVisible())
                self.assertTrue(store.busy("discovery"))
                store.discovery.set()
                self.assertTrue(wait_for(lambda: not store.busy("discovery")))
                app.processEvents()
                self.assertIsNone(window.store)
                self.assertFalse(window.jobs.busy)
            finally:
                store.discovery.set()
                window.close()

    def test_saved_account_shows_loading_and_renders_early_calendar(self):
        with TemporaryDirectory() as folder, patch.dict(os.environ, {"XDG_CACHE_HOME": folder}):
            _, window = self.fixture_window(Path(folder) / "reconnect.ini")
            store = SlowCalendarStore(window.jobs.stopping)
            window.settings.setValue("iCloudEmail", "demo@example.invalid")
            window.settings.setValue("hiddenCalendars", [store.calendars[-2].url])
            try:
                with (patch("calendar_app.keyring.backends.SecretService.Keyring") as keyring,
                      patch("calendar_app.ICloudStore", return_value=store)):
                    keyring.return_value.get_password.return_value = "fixture"
                    window.start()
                    self.assertFalse(window.account.isEnabled())
                    self.assertEqual(window.account.text(), "Connecting…")
                    self.assertTrue(wait_for(lambda: store.busy("discovery")))
                store.early.set()
                store.discovery.set()
                self.assertTrue(wait_for(lambda: window.timeline and len(window.timeline.cards) == 4))
                self.assertTrue(store.busy("visible"))
                self.assertFalse(store.busy("history"))
                self.assertIn("Refreshing calendars", window.status.text())
                store.visible.set()
                self.assertTrue(wait_for(lambda: window.timeline and len(window.timeline.cards) == 56
                                         and "14 calendars" in window.status.text()))
            finally:
                for gate in (store.discovery, store.visible, store.history):
                    gate.set()
                window.close()

    def test_reopen_displays_saved_events_before_icloud_and_browses_offline(self):
        with TemporaryDirectory() as folder:
            directory = Path(folder) / "event-cache"
            cache = CalendarCache("demo@example.invalid", directory)
            store = Mock(spec=ICloudStore)
            calendar = replace(CAL, revision="sync:1")
            series = DATA.replace(b"END:VEVENT", b"RRULE:FREQ=WEEKLY\r\nEND:VEVENT")
            store.event_resources.return_value = [(HREF, '"first"', series)]
            store.discover.return_value = [calendar]
            store.events.side_effect = lambda cal, start, end, zone: list(
                occurrences(cal, HREF, '"first"', series, start, end, zone)
            )
            settings = Path(folder) / "calendar.ini"
            discovery = Gate()

            def offline():
                discovery.wait(5)
                raise CalendarError("No connection.")

            with (patch("calendar_app.keyring.backends.SecretService.Keyring") as keyring,
                  patch("calendar_cache.cache_directory", return_value=directory),
                  patch("calendar_app.ICloudStore", return_value=store)):
                keyring.return_value.get_password.return_value = "fixture"
                _, first_window = self.fixture_window(settings)
                first_window.settings.setValue("iCloudEmail", "demo@example.invalid")
                try:
                    first_window.start()
                    self.assertTrue(wait_for(lambda: first_window.cached_urls == {CAL.url}))
                    self.assertTrue(cache.path.exists())
                finally:
                    first_window.close()

                store.events.reset_mock()
                store.discover.side_effect = offline
                _, window = self.fixture_window(settings)
                try:
                    window.start()
                    self.assertTrue(wait_for(lambda: window.timeline and len(window.timeline.cards) == 1))
                    self.assertTrue(window.connecting)
                    self.assertEqual(window.account.text(), "iCloud")
                    self.assertEqual(window.status.text(), "Showing saved calendars")
                    discovery.set()
                    self.assertTrue(wait_for(lambda: not window.connecting))
                    window.advance(2)
                    self.assertTrue(wait_for(lambda: window.timeline.days == window.window_days()
                                             and len(window.timeline.cards) == 1))
                    self.assertIsNone(window.store)
                    store.events.assert_not_called()
                finally:
                    discovery.set()
                    window.close()

    def test_missing_saved_credential_restores_sign_in(self):
        from pathlib import Path
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as folder:
            _, window = self.fixture_window(Path(folder) / "missing-credential.ini")
            window.settings.setValue("iCloudEmail", "demo@example.invalid")
            try:
                with (patch("calendar_app.keyring.backends.SecretService.Keyring") as keyring,
                      patch("calendar_app.ICloudStore") as store):
                    keyring.return_value.get_password.return_value = None
                    window.start()
                    self.assertTrue(wait_for(lambda: window.account.isEnabled()))
                    self.assertEqual(window.account.text(), "Connect iCloud")
                    store.assert_not_called()
            finally:
                window.close()

    def test_delayed_layout_keeps_gui_responsive_and_only_draws_current_view(self):
        from pathlib import Path
        from tempfile import TemporaryDirectory

        from PySide6 import QtCore, QtWidgets
        from calendar_app import CalendarWindow, Core, ZONE

        app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
        with TemporaryDirectory() as folder:
            gate = Path(folder) / "release"
            launcher = Path(folder) / "slow-core"
            binary = os.environ["CALENDAR_CORE_TEST_BIN"]
            launcher.write_text(
                f"#!{sys.executable}\nimport os, sys, time\n"
                f"while not os.path.exists({str(gate)!r}):\n    time.sleep(0.01)\n"
                f"os.execv({binary!r}, [{binary!r}, *sys.argv[1:]])\n"
            )
            launcher.chmod(0o700)
            prefs = QtCore.QSettings(str(Path(folder) / "slow-layout.ini"), QtCore.QSettings.Format.IniFormat)
            window = CalendarWindow(Core(str(launcher)), clock=lambda: datetime(2026, 11, 21, 13, tzinfo=ZONE),
                                    settings=prefs)
            window.show()
            window.store = object()
            try:
                with patch.object(window, "refresh", side_effect=lambda **_: window.render()):
                    window.render()
                    self.assertTrue(wait_for(lambda: window.layout_bridge.active is not None))
                    process = window.layout_bridge.process.processId()
                    QtCore.QTimer.singleShot(0, lambda: window.change_view("Month"))
                    self.assertTrue(wait_for(lambda: window.mode == "Month"))
                    self.assertFalse(gate.exists())
                    self.assertIsNone(window.timeline)
                    window.change_view("Day")
                    gate.touch()
                    self.assertTrue(wait_for(lambda: window.timeline is not None))
                    self.assertEqual(window.timeline.days, [window.day])
                    window.change_view("Week")
                    self.assertTrue(wait_for(lambda: len(window.timeline.days) == 7))
                    self.assertEqual(window.layout_bridge.process.processId(), process)
            finally:
                window.close()
                app.processEvents()

    def test_busy_week_recycles_offscreen_cards_and_keeps_the_viewport(self):
        from PySide6 import QtCore, QtTest
        from calendar_app import Event, midnight
        from calendar_timeline import ActivityCard, CARD_POOL_LIMIT

        with TemporaryDirectory() as folder:
            app, window = self.fixture_window(Path(folder) / "busy-week.ini")
            window.store = object()
            window.calendars = [CAL]

            def populate(days):
                return [Event(f"{day}-{slot}", CAL, HREF, "", f"Fixture event {slot}", start,
                              start + timedelta(minutes=15), False, "", b"", False)
                        for day in days for slot in range(72)
                        for start in [midnight(day) + timedelta(minutes=slot * 20)]]

            try:
                window.events = populate(window.window_days())
                window.render()
                self.assertTrue(wait_for(lambda: window.timeline is not None))
                timeline = window.timeline
                bar = timeline.area.verticalScrollBar()
                bar.setValue(0)
                app.processEvents()
                self.assertEqual(len(timeline.cards), 504)
                first_widgets = set(timeline.live_cards.values())
                self.assertLess(len(first_widgets), 350)
                bar.setValue(bar.maximum())
                app.processEvents()
                QtCore.QCoreApplication.sendPostedEvents(None, QtCore.QEvent.Type.DeferredDelete)
                self.assertTrue(first_widgets & set(timeline.live_cards.values()))
                total_widgets = timeline.findChildren(ActivityCard, options=QtCore.Qt.FindChildOption.FindDirectChildrenOnly)
                self.assertLessEqual(len(total_widgets), len(timeline.live_cards) + CARD_POOL_LIMIT)
                visible_indexes = [index for index in timeline.live_cards if timeline.cards[index].top >= bar.value()]
                index = visible_indexes[0]
                entry = timeline.live_cards[index]
                with patch.object(window, "open_editor") as open_event:
                    QtTest.QTest.mouseClick(entry, QtCore.Qt.MouseButton.LeftButton, pos=entry.rect().center())
                    open_event.assert_called_once_with(timeline.cards[index].item)
                scroll = bar.value()
                window.day += timedelta(days=7)
                days = window.window_days()
                window.events = populate(days)
                window.render()
                self.assertTrue(wait_for(lambda: window.timeline.days == days))
                self.assertIs(window.timeline, timeline)
                self.assertEqual(bar.value(), scroll)
            finally:
                window.close()

    def test_month_reuses_cells_and_keeps_midnight_boundaries(self):
        from calendar_app import Event, midnight

        with TemporaryDirectory() as folder:
            _, window = self.fixture_window(Path(folder) / "month.ini")
            window.store = object()
            window.mode = "Month"
            start = midnight(window.day)
            whole_day = Event("all-day", CAL, HREF, "", "Fixture day", start, start + timedelta(days=1),
                              True, "", b"", False)
            point = Event("next-day", CAL, HREF, "", "Fixture point", whole_day.end, whole_day.end,
                          False, "", b"", False)
            try:
                window.events = [whole_day, point]
                window.render()
                page = window.month_page
                index = window.window_days().index(window.day)
                self.assertEqual(page.cells[index].items, [whole_day])
                self.assertEqual(page.cells[index + 1].items, [point])
                first = page.cells[0]
                window.day = window.shift_month(window.day, 1)
                window.events = []
                window.render()
                self.assertIs(window.month_page, page)
                self.assertIs(page.cells[0], first)
                self.assertEqual(first.day, window.window_days()[0])
            finally:
                window.close()

    def test_interact_then_close_during_calendar_refresh_and_history_import(self):
        from pathlib import Path
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as folder:
            app, window = self.fixture_window(Path(folder) / "refresh.ini")
            store = SlowCalendarStore(window.jobs.stopping)
            window.settings.setValue("hiddenCalendars", [store.calendars[-1].url])
            try:
                store.discovery.set()
                with patch("calendar_app.ICloudStore", return_value=store):
                    window.connect_account("demo@example.invalid", "fixture", remember=False)
                self.assertTrue(wait_for(lambda: store.busy("visible")))
                self.assertFalse(store.busy("history"))
                self.interact_during_load(window)
                self.assertFalse(store.busy("history"))

                from PySide6 import QtCore, QtWidgets

                previous_track = window.timeline.track if window.timeline else None

                def view_updated():
                    return window.timeline is not None and window.timeline.track is not previous_track

                rendered_during_dialog = []
                deadline = monotonic() + 3

                def close_after_visible_result():
                    if len(window.events) != 54 and monotonic() < deadline:
                        QtCore.QTimer.singleShot(20, close_after_visible_result)
                        return
                    rendered_during_dialog.append(view_updated())
                    modal = QtWidgets.QApplication.activeModalWidget()
                    if modal:
                        modal.reject()

                QtCore.QTimer.singleShot(25, store.visible.set)
                QtCore.QTimer.singleShot(60, close_after_visible_result)
                window.open_settings()
                self.assertEqual(rendered_during_dialog, [False])
                self.assertTrue(wait_for(lambda: store.busy("history")))
                self.assertTrue(wait_for(view_updated))
                self.assertEqual(len(window.calendars), 15)
                self.assertEqual(len(window.events), 54)
                self.assertIn("14 calendars", window.status.text())

                store.visible.clear()
                self.interact_during_load(window)
                self.assertTrue(wait_for(lambda: store.busy("visible") and store.busy("history")))
                window.close()
                self.assertFalse(window.isVisible())
                self.assertTrue(store.busy("visible") and store.busy("history"))
                before = window.events
                store.visible.set()
                store.history.set()
                self.assertTrue(wait_for(lambda: not store.busy("visible") and not store.busy("history")))
                app.processEvents()
                self.assertIs(window.events, before)
                self.assertFalse(window.jobs.busy)
            finally:
                for gate in (store.discovery, store.visible, store.history):
                    gate.set()
                window.close()

    def test_demo_and_shared_quick_entry(self):
        from PySide6 import QtCore, QtTest, QtWidgets
        from calendar_app import CalendarWindow, Core, Editor, ZONE, demo
        from desktop_style import DesktopStyle, contrast
        from calendar_settings import Buffer, Preferences, Profile, SettingsDialog
        from calendar_timeline import TRACK_PAD

        app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
        app.setOrganizationName("CalendarFixture")
        app.setApplicationName("Disposable")
        core = Core(os.environ["CALENDAR_CORE_TEST_BIN"])
        app.setStyle("Fusion")
        from pathlib import Path
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as folder:
            Path(folder, "kdeglobals").write_text(
                "[Colors:Window]\nBackgroundNormal=32,36,42\n"
                "[Colors:Selection]\nBackgroundNormal=61,174,233\n"
            )
            with patch.dict(os.environ, {"XDG_CURRENT_DESKTOP": "KDE", "XDG_CONFIG_HOME": folder}):
                system = DesktopStyle("System")
                self.assertTrue(system.dark)
                self.assertEqual(system.accent, "#3daee9")
                self.assertGreaterEqual(contrast(system.accent, system.on_accent), 4.5)
        fixed_now = datetime(2026, 11, 21, 13, 42, tzinfo=ZONE)
        QtCore.QSettings().clear()
        window = CalendarWindow(core, clock=lambda: fixed_now)
        window.set_appearance("Dark")
        window.show()
        demo(window)

        def settle():
            self.assertTrue(wait_for(lambda: not window.jobs.busy and not window.layout_bridge.busy))
            app.processEvents()

        settle()
        key = window.calendars[0].url
        window.source_widgets[key].click()
        settle()
        self.assertIn(key, window.hidden())
        self.assertTrue(all(event.calendar.url != key for event in window.events))
        window.source_widgets[key].click()
        settle()
        self.assertNotIn(key, window.hidden())
        original_day = window.day
        window.mini_buttons[0].click()
        settle()
        self.assertNotEqual(original_day, window.day)
        window.today()
        settle()
        window.resize(740, 510)
        app.processEvents()
        self.assertTrue(window.navigator.isHidden())
        self.assertEqual(window.add.accessibleName(), "New event (Ctrl+N)")
        window.resize(1280, 800)
        app.processEvents()
        self.assertFalse(window.navigator.isHidden())
        for view in ("Day", "Week", "Month"):
            window.change_view(view)
            settle()
            self.assertEqual(window.mode, view)
            self.assertGreater(len(window.findChildren(QtWidgets.QPushButton)), 10)
        window.change_view("Day")
        settle()
        editor = Editor(window, calendars=window.calendars)
        editor.quick.setText("15:25 15:30 Equipment check 11m before 5m after /Work")
        editor.parse()
        self.assertEqual(editor.title.text(), "Equipment check")
        self.assertEqual(editor.end.dateTime().toSecsSinceEpoch() - editor.start.dateTime().toSecsSinceEpoch(), 300)
        self.assertEqual(editor.buffers["before"], Buffer(11))
        self.assertEqual(editor.buffers["after"], Buffer(5))
        self.assertEqual(editor.calendar.currentData().title, "Work")
        editor.notes.setPlainText("Fixture description")
        editor.buffers["after"] = Buffer(17, "Travel", "Train", "Return trip")
        editor.save()
        settle()
        settle()
        saved = next(event for event in window.events if event.title == "Equipment check")
        activity = core.call("activity", notes=saved.notes)
        self.assertEqual(activity["after"]["travelMode"], "Train")
        self.assertEqual(activity["after"]["label"], "Return trip")
        self.assertEqual(activity["description"], "Fixture description")
        self.assertEqual(saved.end.timestamp() - saved.start.timestamp(), 300)
        track = window.timeline.track[0]
        card = next(card for card in track["cards"] if card["id"] == saved.key)
        self.assertEqual(card["before"]["minutes"], 11)
        self.assertGreaterEqual(card["coreTop"], 20)
        self.assertGreater(card["height"], card["coreBottom"])
        reopened = Editor(window, saved, calendars=(saved.calendar,))
        self.assertEqual(reopened.buffers["after"], Buffer(17, "Travel", "Train", "Return trip"))
        reopened.close()

        note = core.call("saveActivity", notes="", description="Fixture",
                         buffers={"before": {"minutes": 20, "kind": "Travel",
                                             "travelMode": "Walking", "label": ""}, "after": None})
        base = fixed_now.replace(hour=9, minute=0).timestamp()
        cases = [{"id": "core", "start": base, "end": base + 1200},
                 {"id": "with-travel", "start": base + 1800, "end": base + 3600, "notes": note}]
        track, = core.call("layout", days=[base], items=cases, blend=True, pointsPerHour=60)
        core_card = next(item for item in track["cards"] if item["id"] == "core")
        self.assertEqual(core_card["trailing"], 1)
        self.assertEqual(core_card["markers"], [{"owner": "with-travel", "start": 10, "end": 20}])

        settings = SettingsDialog(window)
        membership = [window.calendars[3].url, window.calendars[0].url]
        settings.values.profiles.append(Profile("focus", "Focus", membership, "#8261e6"))
        settings.update_profiles("focus")
        settings.snap.setCurrentIndex(settings.snap.findData(30))
        settings.before.minutes.setValue(12)
        settings.accept()
        settle()
        self.assertEqual(window.look.accent, "#8261e6")
        self.assertEqual([item.url for item in window.writable_calendars()], membership)
        self.assertEqual(Preferences.load(window.settings).before.minutes, 12)
        self.assertTrue(all(event.calendar.url in membership for event in window.events))
        window.select_profile("")
        settle()
        self.assertEqual(len(window.writable_calendars()), 4)

        chosen = window.calendars[0]
        from calendar_app import Draft
        from datetime import timedelta
        for day in (2, 6, 10):
            start = fixed_now - timedelta(days=day)
            window.store.save(chosen, Draft("Fixture review", start, start + timedelta(minutes=30), ""))
        window.history.open("seed-fixture")
        settle()
        self.assertTrue(window.history.seeded)
        self.assertEqual(window.history.suggest("Fixture review", window.writable_calendars(), None),
                         {"id": chosen.url, "suggested": True})
        for _ in range(3):
            window.history.record("Sample appointment", chosen, fixed_now)
        forecast = Editor(window, calendars=window.writable_calendars())
        forecast.title.setText(" sample APPOINTMENT ")
        QtTest.QTest.qWait(210)
        self.assertEqual(forecast.calendar.currentData(), chosen)
        self.assertFalse(forecast.suggestion_row.isHidden())
        forecast.dismiss_suggestion.click()
        self.assertFalse(forecast.calendar.currentData())
        forecast.quick.setText("Sample appointment /Personal")
        forecast.parse()
        self.assertEqual(forecast.calendar.currentData().title, "Personal")
        forecast.close()

        window.installed_revision = "a" * 40
        panel = SettingsDialog(window)
        with patch("calendar_app.latest_revision", return_value="b" * 40):
            panel.check.click()
            settle()
        self.assertEqual(window.remote_revision, "b" * 40)
        self.assertFalse(window.update_notice.isHidden())
        self.assertTrue(panel.install.isEnabled())
        panel.close()

        captures = []

        def receive(event=None, selection=None):
            self.assertIsNone(event)
            draft = Editor(window, calendars=window.writable_calendars(), selection=selection)
            captures.append((draft.start.dateTime().toSecsSinceEpoch(), draft.end.dateTime().toSecsSinceEpoch()))
            draft.close()

        with patch.object(window, "open_editor", side_effect=receive):
            for mode, column in (("Day", 0), ("Week", 0)):
                window.change_view(mode)
                settle()
                timeline = window.timeline
                bar = timeline.area.verticalScrollBar()
                ruler = timeline.track[column]["snap"]
                first, last = ruler[32], ruler[34]
                bar.setValue(round(first["top"]) - 45)
                QtTest.QTest.qWait(30)
                x = (timeline.x(column) + timeline.x(column + 1)) // 2
                a, b = (QtCore.QPoint(x, round(point["top"]) + TRACK_PAD) for point in (first, last))
                QtTest.QTest.mousePress(timeline, QtCore.Qt.MouseButton.LeftButton, pos=b)
                QtTest.QTest.mouseMove(timeline, a, delay=30)
                QtTest.QTest.mouseRelease(timeline, QtCore.Qt.MouseButton.LeftButton, pos=a)
                QtTest.QTest.qWait(50)
                self.assertEqual(captures[-1], (int(first["time"]), int(last["time"])))
            self.assertEqual(len(captures), 2)

        window.change_view("Day")
        settle()
        timeline = window.timeline
        index, placement = next((index, placement) for index, placement in enumerate(timeline.cards)
                                if placement.item.key == saved.key)
        timeline.area.verticalScrollBar().setValue(placement.top - 90)
        self.assertTrue(wait_for(lambda: index in timeline.live_cards))
        entry = timeline.live_cards[index]
        point = QtCore.QPoint(entry.width() // 2, round(entry.geometry_data["coreBottom"]) - 2)
        original_end = saved.end.timestamp()
        target_y = timeline.displayed_top(0, original_end + 1800)
        dy = round(target_y - timeline.displayed_top(0, original_end))
        QtTest.QTest.qWait(30)
        QtTest.QTest.mousePress(entry, QtCore.Qt.MouseButton.LeftButton, pos=point)
        QtTest.QTest.mouseMove(entry, point + QtCore.QPoint(0, dy), delay=50)
        QtTest.QTest.mouseRelease(entry, QtCore.Qt.MouseButton.LeftButton, pos=point + QtCore.QPoint(0, dy))
        QtTest.QTest.qWait(70)
        settle()
        settle()
        resized = next(event for event in window.events if event.title == saved.title)
        self.assertEqual(resized.end.timestamp(), original_end + 1800)
        self.assertEqual(resized.start, saved.start)
        self.assertEqual(resized.notes, saved.notes)

        window.render()
        app.processEvents()
        screenshot = os.environ.get("CALENDAR_FIXTURE_SCREENSHOT")
        if screenshot:
            output = Path(screenshot)
            output.mkdir(parents=True, exist_ok=True)
            window.timeline_scroll = None
            for mode, scheme in (("Week", "Dark"), ("Month", "Light"), ("Day", "Dark")):
                window.change_view(mode)
                settle()
                window.set_appearance(scheme)
                QtTest.QTest.qWait(50)
                self.assertTrue(window.grab().save(str(output / f"{mode.lower()}-{scheme.lower()}.png")))
            editor = Editor(window, calendars=window.calendars)
            editor.show()
            app.processEvents()
            self.assertTrue(editor.grab().save(str(output / "editor-dark.png")))
            editor.close()
            options = SettingsDialog(window)
            options.tabs.setCurrentIndex(2)
            options.show()
            app.processEvents()
            self.assertTrue(options.grab().save(str(output / "timing-settings.png")))
            options.close()
            window.resize(740, 510)
            window.change_view("Week")
            settle()
            QtTest.QTest.qWait(50)
            self.assertTrue(window.grab().save(str(output / "week-narrow.png")))
        window.close()
