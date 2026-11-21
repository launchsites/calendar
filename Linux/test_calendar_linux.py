"""Disposable CalDAV fixtures and desktop smoke coverage."""

import os
from datetime import datetime, timezone
import unittest
from unittest.mock import patch

import icalendar
import requests

from caldav_store import Calendar, CalendarError, Draft, ICloudStore, cloud_url, occurrences


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
            self.assertEqual(store.discover(), [Calendar(CAL.url, "Work", "#5489df", False)])

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


class InstallTests(unittest.TestCase):
    def test_desktop_identity_uses_the_calendar_icon_and_installed_revision(self):
        from pathlib import Path
        from tempfile import TemporaryDirectory
        from calendar_install import APP_ID, ROOT, icon_png, install, installed_revision

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
            png = home / f"icons/hicolor/1024x1024/apps/{APP_ID}.png"
            self.assertEqual(png.read_bytes(), icon_png())
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


@unittest.skipUnless(os.environ.get("CALENDAR_CORE_TEST_BIN"), "requires the built Swift helper")
class DesktopTests(unittest.TestCase):
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
            self.assertTrue(window.pool.waitForDone(5000))
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
        _, _, entry = next(card for card in timeline.cards if card[2].item.key == saved.key)
        timeline.area.verticalScrollBar().setValue(entry.y() - 90)
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
