"""Calendar's Linux desktop window."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from datetime import date, datetime, time, timedelta
from pathlib import Path
import subprocess
import sys
from uuid import uuid4
from zoneinfo import ZoneInfo

import keyring.backends.SecretService
from PySide6 import QtCore, QtGui, QtWidgets as Qt
from tzlocal import get_localzone

from caldav_store import Calendar, CalendarError, Draft, Event, ICloudStore, local_time
from desktop_style import CheckBox, DesktopStyle, EventButton, button, icon, label, mix


ZONE = get_localzone()
SERVICE = "com.example.stillday.calendar.linux"


def midnight(day):
    return datetime.combine(day, time.min, ZONE)


def from_epoch(value):
    return datetime.fromtimestamp(value, ZONE)


class Core:
    def __init__(self, binary):
        self.binary = binary

    def call(self, operation, **payload):
        try:
            process = subprocess.run(
                [self.binary], input=json.dumps({"operation": operation, "timeZone": str(ZONE), **payload}),
                text=True, capture_output=True, timeout=5, check=True,
            )
            response = json.loads(process.stdout)
        except (OSError, ValueError, subprocess.SubprocessError):
            raise CalendarError("Calendar’s shared engine could not run. Run Scripts/setup-linux again.") from None
        if "error" in response:
            raise CalendarError(response["error"])
        return response["value"]


class WorkerSignals(QtCore.QObject):
    done = QtCore.Signal(object, str)


class Worker(QtCore.QRunnable):
    def __init__(self, action):
        super().__init__()
        self.action = action
        self.signals = WorkerSignals()

    def run(self):
        try:
            result = self.action()
        except CalendarError as error:
            self.signals.done.emit(None, str(error))
        except Exception:
            self.signals.done.emit(None, "An event or calendar response could not be read. Try refreshing.")
        else:
            self.signals.done.emit(result, "")


class Editor(Qt.QDialog):
    def __init__(self, window, event=None, calendars=()):
        super().__init__(window)
        self.owner, self.original = window, event
        caption = "Event details" if event else "New event"
        self.setWindowTitle(caption)
        self.resize(520, 395)
        form = Qt.QFormLayout(self)
        form.setContentsMargins(20, 17, 20, 17)
        form.setHorizontalSpacing(16)
        form.setVerticalSpacing(9)
        form.addRow(label(caption, size=22, weight=QtGui.QFont.Weight.DemiBold))
        if not event:
            self.quick = Qt.QLineEdit(placeholderText="e.g. 15:25 15:30 Equipment check 11m before 5m after")
            self.mode = Qt.QComboBox()
            self.mode.addItem("Schedule ahead", "schedule")
            self.mode.addItem("Log activity", "log")
            parse = button("Apply", "secondary")
            parse.clicked.connect(self.parse)
            row = Qt.QHBoxLayout()
            row.addWidget(self.quick, 1)
            row.addWidget(parse)
            form.addRow("Quick entry", row)
            form.addRow("Mode", self.mode)
        self.title = Qt.QLineEdit(event.title if event else "")
        self.all_day = CheckBox("All day")
        self.start, self.end = Qt.QDateTimeEdit(), Qt.QDateTimeEdit()
        now = window.now()
        slot = midnight(window.day) + timedelta(hours=now.hour if window.day == now.date() else 9)
        self.set_times(event.start if event else slot, event.end if event else slot + timedelta(hours=1),
                       event.all_day if event else False)
        for editor in (self.start, self.end):
            editor.setCalendarPopup(True)
        self.all_day.toggled.connect(self.update_format)
        self.update_format()
        self.calendar = Qt.QComboBox()
        if len(calendars) > 1 and not event:
            self.calendar.addItem("Choose a calendar", None)
        for calendar in calendars:
            self.calendar.addItem(calendar.title, calendar)
        self.notes = Qt.QPlainTextEdit()
        self.notes.setTabChangesFocus(True)
        self.notes.setPlaceholderText("Add a description")
        self.raw_notes = event.notes if event else ""
        self.initial_description = window.core.call("describe", notes=self.raw_notes)
        self.notes.setPlainText(self.initial_description)
        self.weekly = CheckBox("Repeat weekly")
        self.entry_zone = None
        self.status = Qt.QLabel(wordWrap=True)
        form.addRow("Title", self.title)
        form.addRow("", self.all_day)
        form.addRow("Starts", self.start)
        form.addRow("Ends", self.end)
        if not event:
            form.addRow("", self.weekly)
        form.addRow("Calendar", self.calendar)
        form.addRow("Description", self.notes)
        form.addRow(self.status)

        editable = event.editable if event else bool(calendars)
        self.buttons = Qt.QDialogButtonBox(Qt.QDialogButtonBox.StandardButton.Cancel |
                                           Qt.QDialogButtonBox.StandardButton.Save) if editable else Qt.QDialogButtonBox(
                                               Qt.QDialogButtonBox.StandardButton.Close)
        self.buttons.rejected.connect(self.reject)
        self.buttons.accepted.connect(self.save)
        for control in self.buttons.buttons():
            control.setIcon(QtGui.QIcon())
        save = self.buttons.button(Qt.QDialogButtonBox.StandardButton.Save)
        if save:
            save.setProperty("variant", "primary")
        if event and editable:
            delete = self.buttons.addButton("Delete event", Qt.QDialogButtonBox.ButtonRole.DestructiveRole)
            delete.clicked.connect(self.delete)
        if not editable:
            self.status.setText("This event is read-only." if event else "Connect a writable calendar to save events.")
            self.title.setReadOnly(True)
            self.notes.setReadOnly(True)
            for control in (self.calendar, self.all_day, self.start, self.end):
                control.setEnabled(False)
        form.addRow(self.buttons)
        if event:
            self.title.setFocus()
        else:
            self.quick.setFocus()
            self.quick.returnPressed.connect(self.parse)

    def set_times(self, start, end, all_day):
        self.start.setDateTime(QtCore.QDateTime.fromSecsSinceEpoch(round(start.timestamp())))
        self.end.setDateTime(QtCore.QDateTime.fromSecsSinceEpoch(round(end.timestamp())))
        self.all_day.setChecked(all_day)

    def update_format(self):
        all_day = self.all_day.isChecked()
        for editor in (self.start, self.end):
            editor.setDisplayFormat("ddd d MMM yyyy" if all_day else "ddd d MMM yyyy  HH:mm")
        if all_day and self.end.date() <= self.start.date():
            self.end.setDate(self.start.date().addDays(1))

    def parse(self):
        try:
            result = self.owner.core.call("parse", text=self.quick.text(), slot=self.start.dateTime().toSecsSinceEpoch(),
                                           mode=self.mode.currentData())
            self.title.setText(result["title"])
            self.set_times(from_epoch(result["start"]), from_epoch(result["end"]), result["allDay"])
            self.weekly.setChecked(result["repeatWeekly"])
            self.raw_notes = result["notes"]
            self.entry_zone = result["timeZone"]
            notice = result["notice"]
            requested = result["requestedCalendar"]
            if requested:
                matches = [i for i in range(self.calendar.count()) if self.calendar.itemData(i)
                           and self.calendar.itemText(i).casefold() == requested.casefold()]
                self.calendar.setCurrentIndex(matches[0] if len(matches) == 1 else -1)
                if len(matches) != 1:
                    self.status.setText(f"Choose the calendar to use for /{requested}.")
                    return
            self.status.setText(notice or "Review the event, then save.")
        except CalendarError as error:
            self.status.setText(str(error))

    def save(self):
        calendar = self.calendar.currentData()
        if calendar is None:
            self.status.setText("Choose a writable calendar.")
            return
        start, end = (from_epoch(editor.dateTime().toSecsSinceEpoch()) for editor in (self.start, self.end))
        if self.all_day.isChecked():
            start, end = start.date(), end.date()
        elif self.entry_zone:
            start, end = (value.astimezone(ZoneInfo(self.entry_zone)) for value in (start, end))
        try:
            description = self.notes.toPlainText()
            notes = self.raw_notes if description == self.initial_description else self.owner.core.call(
                "replaceDescription", notes=self.raw_notes, description=description)
        except CalendarError as error:
            self.status.setText(str(error))
            return
        draft = Draft(self.title.text().strip(), start, end, notes, not self.original and self.weekly.isChecked())
        if not draft.title or (end <= start if type(start) is date else end.timestamp() <= start.timestamp()):
            self.status.setText("Enter a title and an end after the start.")
            return
        store = self.owner.store
        self.write(lambda: store.save(calendar, draft, self.original))

    def delete(self):
        answer = Qt.QMessageBox.question(self, "Delete event", f"Delete “{self.original.title}” from iCloud?",
                                         Qt.QMessageBox.StandardButton.Yes | Qt.QMessageBox.StandardButton.Cancel,
                                         Qt.QMessageBox.StandardButton.Cancel)
        if answer == Qt.QMessageBox.StandardButton.Yes:
            store = self.owner.store
            self.write(lambda: store.delete(self.original))

    def write(self, action):
        self.buttons.setEnabled(False)
        self.status.setText("Applying changes…")
        self.writing = True

        def finish(result, error):
            self.writing = False
            self.buttons.setEnabled(True)
            if error:
                self.status.setText(error)
            else:
                self.accept()
                self.owner.refresh()

        self.owner.work(action, finish)

    def reject(self):
        if not getattr(self, "writing", False):
            super().reject()


GUTTER = 58
TRACK_PAD = 10
SCROLLBAR = 10


class Timeline(Qt.QWidget):
    def __init__(self, owner, days, layout, events):
        super().__init__()
        self.owner, self.days, self.track = owner, days, layout
        self.look = owner.look
        self.today = owner.now().date()
        by_key = {event.key: event for event in events}
        self.setMinimumHeight(int(max(x["height"] for x in layout)) + TRACK_PAD * 2)
        self.setSizePolicy(Qt.QSizePolicy.Policy.Expanding, Qt.QSizePolicy.Policy.Fixed)
        self.cards = []
        for column, data in enumerate(layout):
            for card in data["cards"]:
                event = by_key[card["id"]]
                times = event.start.strftime("%H:%M") + " – " + event.end.strftime("%H:%M")
                entry = EventButton(event, self.look, caption=times, parent=self)
                entry.clicked.connect(lambda checked=False, item=event: self.owner.open_editor(item))
                self.cards.append((column, card, entry))
        self.buffers = [(i, band, by_key[band["id"]].calendar.color)
                        for i, day in enumerate(layout) for band in day["buffers"]]
        self.clock = NowMarker(self)
        self.clock.raise_()

    def x(self, column):
        return round(GUTTER + column * (self.width() - GUTTER) / len(self.days))

    def resizeEvent(self, event):
        for column, card, entry in self.cards:
            left = self.x(column + card["leading"]) + 4
            right = self.x(column + card["trailing"]) - 4
            entry.setGeometry(left, round(card["top"]) + TRACK_PAD + 1, max(1, right - left),
                              max(1, round(card["height"]) - 2))
        self.clock.setGeometry(self.rect())
        super().resizeEvent(event)

    def paintEvent(self, event):
        p = QtGui.QPainter(self)
        look = self.look
        p.fillRect(event.rect(), QtGui.QColor(look.surface))
        font = self.font()
        font.setPixelSize(11)
        p.setFont(font)
        for column, (day, data) in enumerate(zip(self.days, self.track)):
            left, right = self.x(column), self.x(column + 1)
            if day == self.today:
                p.fillRect(left, 0, right - left, self.height(), QtGui.QColor(look.today_column))
            elif day.weekday() >= 5:
                p.fillRect(left, 0, right - left, self.height(), QtGui.QColor(look.weekend))
            p.setPen(QtGui.QColor(look.grid))
            p.drawLine(left, 0, left, self.height())
            for hour in data["hours"]:
                y = round(hour["top"]) + TRACK_PAD
                p.setPen(QtGui.QColor(look.grid))
                p.drawLine(left, y, right, y)
                if column == 0:
                    p.setPen(QtGui.QColor(look.muted))
                    p.drawText(QtCore.QRect(0, y - 9, GUTTER - 12, 18),
                               QtCore.Qt.AlignmentFlag.AlignRight | QtCore.Qt.AlignmentFlag.AlignVCenter,
                               from_epoch(hour["start"]).strftime("%H:%M"))
        for column, band, color in self.buffers:
            left, right = self.x(column) + 4, self.x(column + 1) - 4
            y = round(band["top"]) + TRACK_PAD
            height = round(band["height"])
            if height <= 0:
                continue
            p.fillRect(left, y, max(1, right - left), height, QtGui.QColor(mix(color, look.surface, 0.12)))
            p.setPen(QtGui.QPen(QtGui.QColor(color), 2, QtCore.Qt.PenStyle.DotLine))
            p.drawLine(left + 4, y, left + 4, y + height)
            if height >= 17:
                p.setPen(QtGui.QColor(look.muted))
                caption = p.fontMetrics().elidedText(band["label"], QtCore.Qt.TextElideMode.ElideRight,
                                                     max(0, right - left - 17))
                p.drawText(left + 11, y + 13, caption)


class NowMarker(Qt.QWidget):
    def __init__(self, timeline):
        super().__init__(timeline)
        self.timeline = timeline
        self.setAttribute(QtCore.Qt.WidgetAttribute.WA_TransparentForMouseEvents)

    def paintEvent(self, event):
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
        look = self.timeline.look
        accent = QtGui.QColor(look.accent)
        for column, day in enumerate(self.timeline.track):
            if day["now"] is None:
                continue
            y = round(day["now"]) + TRACK_PAD
            left, right = self.timeline.x(column), self.timeline.x(column + 1)
            p.setPen(QtGui.QPen(accent, 1.5))
            p.drawLine(left, y, right, y)
            p.setBrush(accent)
            p.drawEllipse(QtCore.QPoint(left, y), 3, 3)
            p.setPen(QtCore.Qt.PenStyle.NoPen)
            p.drawRoundedRect(QtCore.QRectF(6, y - 9, GUTTER - 13, 18), 5, 5)
            font = self.font()
            font.setPixelSize(11)
            font.setWeight(QtGui.QFont.Weight.DemiBold)
            p.setFont(font)
            p.setPen(QtGui.QColor(look.on_accent))
            p.drawText(QtCore.QRect(6, y - 9, GUTTER - 13, 18), QtCore.Qt.AlignmentFlag.AlignCenter,
                       self.timeline.owner.now().strftime("%H:%M"))


class CalendarWindow(Qt.QMainWindow):
    def __init__(self, core, clock=None):
        super().__init__()
        self.core = core
        self.now = clock or (lambda: datetime.now(ZONE))
        self.settings = QtCore.QSettings()
        self.pool = QtCore.QThreadPool(self)
        self.pool.setMaxThreadCount(2)
        self.workers = set()
        self.day, self.mode = self.now().date(), "Week"
        self.navigator_month = self.day.replace(day=1)
        self.store, self.calendars, self.events = None, [], []
        self.reading = False
        self.refresh_pending = False
        self.snapshot = None
        self.connecting = False
        self.is_demo = False
        self.sidebar_preferred = self.settings.value("showNavigator", True, bool)
        self.setWindowTitle("Calendar")
        self.resize(1280, 800)
        self.setMinimumSize(710, 490)

        container = Qt.QWidget()
        root = Qt.QVBoxLayout(container)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        self.setCentralWidget(container)
        self.icon_buttons = []
        root.addWidget(self.build_toolbar())
        body = Qt.QHBoxLayout()
        body.setContentsMargins(0, 0, 0, 0)
        body.setSpacing(0)
        self.navigator = self.build_navigator()
        body.addWidget(self.navigator)
        main = Qt.QWidget(objectName="content")
        content = Qt.QVBoxLayout(main)
        content.setContentsMargins(0, 0, 0, 0)
        content.setSpacing(0)
        date_header = Qt.QHBoxLayout()
        date_header.setContentsMargins(22, 16, 22, 13)
        self.heading = label(size=29, weight=QtGui.QFont.Weight.DemiBold)
        self.heading.setSizePolicy(Qt.QSizePolicy.Policy.Ignored, Qt.QSizePolicy.Policy.Preferred)
        date_header.addWidget(self.heading, 1)
        self.range_label = label(tone="muted", size=12, weight=QtGui.QFont.Weight.Medium)
        date_header.addWidget(self.range_label)
        content.addLayout(date_header)
        self.canvas = Qt.QVBoxLayout()
        self.canvas.setSpacing(0)
        content.addLayout(self.canvas, 1)
        body.addWidget(main, 1)
        root.addLayout(body, 1)
        root.addWidget(self.build_status_bar())
        self.appearance = self.settings.value("appearance", "System", str)
        Qt.QApplication.instance().styleHints().colorSchemeChanged.connect(
            lambda scheme: self.apply_appearance() if self.appearance == "System" else None
        )
        self.timer = QtCore.QTimer(self, interval=180000)
        self.timer.timeout.connect(self.refresh)
        self.timer.start()
        self.apply_appearance()

    def icon_button(self, glyph, name, action, *, size=(34, 34)):
        item = button(variant="nav", name=name, size=size)
        item.clicked.connect(action)
        self.icon_buttons.append((item, glyph))
        return item

    def build_toolbar(self):
        bar = Qt.QWidget(objectName="toolbar")
        bar.setFixedHeight(60)
        row = Qt.QHBoxLayout(bar)
        row.setContentsMargins(15, 0, 15, 0)
        row.setSpacing(8)
        self.sidebar_toggle = self.icon_button("panel", "Show or hide calendar navigator", self.toggle_navigator)
        row.addWidget(self.sidebar_toggle)
        row.addSpacing(5)
        row.addWidget(self.icon_button("back", "Previous", lambda: self.advance(-1)))
        today = button("Today")
        today.setMinimumHeight(34)
        today.clicked.connect(self.today)
        row.addWidget(today)
        row.addWidget(self.icon_button("next", "Next", lambda: self.advance(1)))

        row.addStretch()
        switcher = Qt.QWidget(objectName="switcher")
        switcher.setFixedHeight(38)
        segments = Qt.QHBoxLayout(switcher)
        segments.setContentsMargins(4, 3, 4, 3)
        segments.setSpacing(2)
        self.views = Qt.QButtonGroup(self)
        for i, name in enumerate(("Day", "Week", "Month"), 1):
            segment = button(name, "segment", size=(67, 30))
            segment.setCheckable(True)
            segment.setChecked(name == self.mode)
            segment.clicked.connect(lambda checked=False, mode=name: self.change_view(mode))
            self.views.addButton(segment, i)
            segments.addWidget(segment)
            QtGui.QShortcut(QtGui.QKeySequence(f"Ctrl+{i}"), self,
                            activated=lambda mode=name: self.change_view(mode))
        row.addWidget(switcher)
        row.addStretch()

        self.account = button("Connect iCloud")
        self.account.clicked.connect(self.connect_dialog)
        row.addWidget(self.account)
        self.add = button("New event", "primary", name="New event (Ctrl+N)")
        self.add.clicked.connect(lambda: self.open_editor())
        row.addWidget(self.add)
        self.menu_button = self.icon_button("menu", "Calendar menu", self.open_menu)
        row.addWidget(self.menu_button)
        QtGui.QShortcut(QtGui.QKeySequence.StandardKey.New, self, activated=self.open_editor)
        QtGui.QShortcut(QtGui.QKeySequence("Ctrl+R"), self, activated=self.refresh)
        return bar

    def build_navigator(self):
        pane = Qt.QWidget(objectName="navigationPane")
        pane.setFixedWidth(226)
        sidebar = Qt.QVBoxLayout(pane)
        sidebar.setContentsMargins(0, 0, 1, 0)
        sidebar.setSpacing(0)

        scroll = Qt.QScrollArea(widgetResizable=True)
        scroll.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        contents = Qt.QWidget(objectName="navigationBody")
        box = Qt.QVBoxLayout(contents)
        box.setContentsMargins(14, 13, 14, 14)
        box.setSpacing(0)
        month = Qt.QHBoxLayout()
        month.setSpacing(0)
        self.mini_heading = label(size=14, weight=QtGui.QFont.Weight.DemiBold)
        month.addWidget(self.mini_heading, 1)
        month.addWidget(self.icon_button("back", "Previous month in navigator", lambda: self.page_mini(-1), size=(24, 28)))
        month.addWidget(self.icon_button("next", "Next month in navigator", lambda: self.page_mini(1), size=(24, 28)))
        box.addLayout(month)
        box.addSpacing(7)
        mini = Qt.QGridLayout()
        mini.setContentsMargins(0, 0, 0, 0)
        mini.setSpacing(2)
        self.mini_buttons = []
        monday = date(2026, 1, 5)
        for weekday in range(7):
            header = label((monday + timedelta(days=weekday)).strftime("%a")[:2], tone="muted", size=10)
            header.setAlignment(QtCore.Qt.AlignmentFlag.AlignCenter)
            mini.addWidget(header, 0, weekday)
        for index in range(42):
            row, col = divmod(index, 7)
            day = button(variant="date", size=(25, 26))
            day.clicked.connect(lambda checked=False, item=day: self.choose_mini(item.property("day")))
            self.mini_buttons.append(day)
            mini.addWidget(day, row + 1, col)
        box.addLayout(mini)
        box.addSpacing(15)
        line = Qt.QFrame(objectName="separator")
        line.setFixedHeight(1)
        box.addWidget(line)
        box.addSpacing(14)
        box.addWidget(label("Calendars", size=13, weight=QtGui.QFont.Weight.DemiBold))
        box.addSpacing(5)

        self.source_list = Qt.QVBoxLayout()
        self.source_list.setSpacing(1)
        self.source_widgets = {}
        self.source_key = None
        box.addLayout(self.source_list)
        box.addStretch()
        scroll.setWidget(contents)
        sidebar.addWidget(scroll)
        return pane

    def build_status_bar(self):
        bar = Qt.QWidget(objectName="statusBar")
        row = Qt.QHBoxLayout(bar)
        row.setContentsMargins(15, 2, 15, 2)
        self.status_icon = label("●", tone="muted", size=10)
        self.status = label(tone="muted", size=12)
        self.status.setSizePolicy(Qt.QSizePolicy.Policy.Ignored, Qt.QSizePolicy.Policy.Preferred)
        row.addWidget(self.status_icon)
        row.addWidget(self.status, 1)
        self.refresh_button = self.icon_button("refresh", "Refresh calendars (Ctrl+R)", self.refresh, size=(30, 28))
        row.addWidget(self.refresh_button)
        return bar

    def set_status(self, message, state=None):
        self.status.setText(message)
        self.status.setToolTip(message)
        chip = {
            "working": self.look.accent_text,
            "ready": "#72bf90" if self.look.dark else "#278254",
            "error": "#f0a36d" if self.look.dark else "#a95322",
        }.get(state, self.look.muted)
        self.status_icon.setStyleSheet(f"color: {chip};")

    def resizeEvent(self, event):
        super().resizeEvent(event)
        if hasattr(self, "navigator"):
            self.update_bar_width(event.size().width())

    def update_bar_width(self, width):
        self.navigator.setVisible(self.sidebar_preferred and width >= 990)
        self.sidebar_toggle.setEnabled(width >= 990)
        self.sidebar_toggle.setAccessibleName("Show calendar navigator" if self.navigator.isHidden() else
                                              "Hide calendar navigator")
        self.add.setText("New event" if width >= 820 else "")
        self.add.setFixedWidth(111 if width >= 820 else 40)

    def toggle_navigator(self):
        self.sidebar_preferred = not self.sidebar_preferred
        self.settings.setValue("showNavigator", self.sidebar_preferred)
        self.update_bar_width(self.width())

    def apply_appearance(self):
        self.look = DesktopStyle(self.appearance)
        self.look.apply(self)
        for item, glyph in self.icon_buttons:
            item.setIcon(icon(glyph, self.look.muted))
            item.setIconSize(QtCore.QSize(18, 18))
        self.add.setIcon(icon("add", self.look.on_accent))
        self.add.setIconSize(QtCore.QSize(17, 17))
        self.update_bar_width(self.width())
        self.render()

    def open_menu(self):
        menu = Qt.QMenu(self)
        calendars = menu.addAction("Visible calendars…")
        calendars.triggered.connect(self.visibility)
        if not self.is_demo:
            connection = menu.addAction("iCloud connection…")
            connection.triggered.connect(self.connect_dialog)
        appearance_menu = menu.addMenu("Appearance")
        group = QtGui.QActionGroup(menu)
        for name in ("System", "Light", "Dark"):
            action = appearance_menu.addAction(name)
            action.setCheckable(True)
            action.setChecked(self.appearance == name)
            group.addAction(action)
            action.triggered.connect(lambda checked=False, mode=name: self.set_appearance(mode))
        menu.exec(self.menu_button.mapToGlobal(QtCore.QPoint(0, self.menu_button.height() + 4)))

    def set_appearance(self, mode):
        self.appearance = mode
        self.settings.setValue("appearance", mode)
        self.apply_appearance()

    @staticmethod
    def shift_month(day, step):
        first = day.replace(day=1)
        return (first + timedelta(days=32 if step > 0 else -1)).replace(day=1)

    def page_mini(self, step):
        self.navigator_month = self.shift_month(self.navigator_month, step)
        self.update_mini()

    def choose_mini(self, day):
        self.day = day
        self.navigate()

    def update_mini(self):
        first = self.navigator_month
        self.mini_heading.setText(first.strftime("%B %Y"))
        grid_start = first - timedelta(days=first.weekday())
        today = self.now().date()
        days = self.window_days()
        active = set(days if self.mode == "Week" else [self.day])
        for index, item in enumerate(self.mini_buttons):
            day = grid_start + timedelta(days=index)
            item.setText(str(day.day))
            item.setAccessibleName(day.strftime("%A %d %B %Y"))
            item.setToolTip(item.accessibleName())
            item.setProperty("day", day)
            item.setProperty("inRange", day in active)
            item.setProperty("outside", day.month != first.month)
            item.setProperty("today", day == today)
            item.style().unpolish(item)
            item.style().polish(item)

    def update_calendar_list(self):
        key = tuple(self.calendars)
        hidden = self.hidden()
        if self.source_key != key:
            while self.source_list.count():
                old = self.source_list.takeAt(0).widget()
                old.hide()
                old.deleteLater()
            self.source_widgets.clear()
            self.source_key = key
            if not key:
                self.source_list.addWidget(label("No calendars connected", tone="muted", size=12))
            for calendar in self.calendars:
                toggle = CheckBox(calendar.title, color=calendar.color)
                toggle.setToolTip(calendar.title)
                toggle.toggled.connect(lambda shown, url=calendar.url: self.set_calendar_visible(url, shown))
                self.source_widgets[calendar.url] = toggle
                self.source_list.addWidget(toggle)
        for key, toggle in self.source_widgets.items():
            with QtCore.QSignalBlocker(toggle):
                toggle.setChecked(key not in hidden)

    def set_calendar_visible(self, url, visible):
        hidden = self.hidden()
        if visible:
            hidden.discard(url)
        else:
            hidden.add(url)
        self.settings.setValue("hiddenCalendars", sorted(hidden))
        self.navigate()


    def start(self):
        username = self.settings.value("iCloudEmail", "", str)
        if username:
            try:
                password = keyring.backends.SecretService.Keyring().get_password(SERVICE, username)
            except Exception:
                password = None
            if password:
                self.connect_account(username, password, remember=False)

    def work(self, action, done):
        worker = Worker(action)
        self.workers.add(worker)

        def finish(result, error):
            self.workers.discard(worker)
            done(result, error)

        worker.signals.done.connect(finish, QtCore.Qt.ConnectionType.QueuedConnection)
        self.pool.start(worker)

    def window_days(self):
        if self.mode == "Day":
            return [self.day]
        if self.mode == "Week":
            start = self.day - timedelta(days=self.day.weekday())
            return [start + timedelta(days=i) for i in range(7)]
        first = self.day.replace(day=1)
        next_month = (first + timedelta(days=32)).replace(day=1)
        start = first - timedelta(days=first.weekday())
        stop = next_month + timedelta(days=(-next_month.weekday()) % 7)
        return [start + timedelta(days=i) for i in range((stop - start).days)]

    def advance(self, step):
        if self.mode == "Month":
            self.day = self.shift_month(self.day, step)
        else:
            self.day += timedelta(days=step * (7 if self.mode == "Week" else 1))
        self.navigate()

    def change_view(self, mode):
        self.mode = mode
        for button in self.views.buttons():
            button.setChecked(button.text() == mode)
        self.navigate()

    def today(self):
        self.day = self.now().date()
        self.navigate()

    def navigate(self):
        self.navigator_month = self.day.replace(day=1)
        self.render()
        self.refresh()

    def connect_dialog(self):
        if self.connecting:
            return
        dialog = Qt.QDialog(self)
        dialog.setWindowTitle("iCloud connection")
        dialog.setMinimumWidth(450)
        form = Qt.QFormLayout(dialog)
        form.setContentsMargins(20, 17, 20, 17)
        form.setVerticalSpacing(10)
        form.addRow(label("Connect iCloud", size=22, weight=QtGui.QFont.Weight.DemiBold))
        hint = Qt.QLabel('Use an <a href="https://support.apple.com/en-us/102654">Apple app-specific password</a>.')
        hint.setOpenExternalLinks(True)
        form.addRow(hint)
        user = Qt.QLineEdit(self.settings.value("iCloudEmail", "", str))
        secret = Qt.QLineEdit(echoMode=Qt.QLineEdit.EchoMode.Password)
        remember = CheckBox("Remember in the system keyring", checked=True)
        form.addRow("Apple Account email", user)
        form.addRow("App-specific password", secret)
        form.addRow(remember)
        buttons = Qt.QDialogButtonBox(Qt.QDialogButtonBox.StandardButton.Ok |
                                       Qt.QDialogButtonBox.StandardButton.Cancel)
        for control in buttons.buttons():
            control.setIcon(QtGui.QIcon())
        submit = buttons.button(Qt.QDialogButtonBox.StandardButton.Ok)
        submit.setText("Connect")
        submit.setProperty("variant", "primary")
        buttons.accepted.connect(dialog.accept)
        buttons.rejected.connect(dialog.reject)
        form.addRow(buttons)
        if dialog.exec() and user.text().strip() and secret.text().strip():
            self.connect_account(user.text().strip(), secret.text().strip(), remember.isChecked())
            secret.clear()

    def connect_account(self, username, password, remember):
        self.connecting = True
        store = ICloudStore(username, password)
        self.set_status("Connecting to iCloud…", "working")

        def done(calendars, error):
            self.connecting = False
            if error:
                self.set_status(error, "error")
                return
            self.store, self.calendars, self.events, self.snapshot = store, calendars, [], None
            self.account.setText("iCloud")
            self.settings.setValue("iCloudEmail", username)
            self.session_notice = ""
            if remember:
                try:
                    keyring.backends.SecretService.Keyring().set_password(SERVICE, username, password)
                except Exception:
                    self.session_notice = "One-session sign-in. The system keyring is unavailable."
            self.refresh()

        self.work(store.discover, done)

    def visibility(self):
        dialog = Qt.QDialog(self)
        dialog.setWindowTitle("Visible calendars")
        form = Qt.QVBoxLayout(dialog)
        hidden = self.hidden()
        toggles = []
        for calendar in self.calendars:
            toggle = CheckBox(calendar.title, color=calendar.color, checked=calendar.url not in hidden)
            toggles.append((calendar.url, toggle))
            form.addWidget(toggle)
        if not toggles:
            form.addWidget(Qt.QLabel("Connect iCloud to choose calendars."))
        buttons = Qt.QDialogButtonBox(Qt.QDialogButtonBox.StandardButton.Ok |
                                       Qt.QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(dialog.accept)
        buttons.rejected.connect(dialog.reject)
        form.addWidget(buttons)
        if dialog.exec():
            self.settings.setValue("hiddenCalendars", [url for url, toggle in toggles if not toggle.isChecked()])
            self.navigate()

    def hidden(self):
        return set(self.settings.value("hiddenCalendars", [], list))

    def refresh(self):
        if not self.store:
            return
        if self.reading:
            self.refresh_pending = True
            return
        self.reading = True
        days = self.window_days()
        start, end = midnight(days[0]), midnight(days[-1] + timedelta(days=1))
        visible = [item for item in self.calendars if item.url not in self.hidden()]
        store = self.store
        self.set_status("Refreshing calendars…", "working")

        def read():
            def load(calendar):
                try:
                    return store.events(calendar, start, end, ZONE), None
                except CalendarError as error:
                    return [], str(error)
                except (ValueError, TypeError, KeyError):
                    return [], "A calendar returned an unsupported event."

            events, failures = [], []
            with ThreadPoolExecutor(max_workers=4) as executor:
                for records, failure in executor.map(load, visible):
                    events.extend(records)
                    if failure:
                        failures.append(failure)
            return sorted(events, key=lambda event: event.start.timestamp()), failures

        def done(result, error):
            self.reading = False
            current = self.window_days()
            if self.refresh_pending:
                self.refresh_pending = False
                self.refresh()
                return
            if (current[0], current[-1]) != (days[0], days[-1]) or store is not self.store:
                return
            if error:
                self.set_status(error, "error")
                return
            events, failures = result
            if events or not failures or self.snapshot != (days[0], days[-1]):
                self.events, self.snapshot = events, (days[0], days[-1])
                self.render()
            if failures:
                self.set_status(f"{len(failures)} calendar(s) could not refresh. {failures[0]}", "error")
            elif self.is_demo:
                self.set_status("Sample calendars", "ready")
            else:
                count = "1 calendar" if len(visible) == 1 else f"{len(visible)} calendars"
                self.set_status(getattr(self, "session_notice", "") or f"{count} · iCloud up to date", "ready")

        self.work(read, done)

    def events_on(self, day, events):
        start, end = midnight(day), midnight(day + timedelta(days=1))
        return [item for item in events if item.start < end and
                (item.end > start or item.start >= start)]

    def clear_canvas(self):
        while self.canvas.count():
            widget = self.canvas.takeAt(0).widget()
            widget.hide()
            widget.deleteLater()

    def render(self):
        days = self.window_days()
        if self.mode == "Week":
            first, last = days[0], days[-1]
            left = first.strftime("%-d" if first.month == last.month else "%-d %b")
            self.heading.setText(f"{left}–{last.strftime('%-d %B')}")
            self.range_label.setText(f"Week {first.isocalendar().week}  ·  {last.year}")
        elif self.mode == "Day":
            self.heading.setText(self.day.strftime("%A, %-d %B"))
            self.range_label.setText("Today" if self.day == self.now().date() else str(self.day.year))
        else:
            self.heading.setText(self.day.strftime("%B %Y"))
            self.range_label.clear()
        self.update_mini()
        self.update_calendar_list()
        self.clear_canvas()
        if not self.store:
            self.draw_empty()
            if not self.status.text():
                self.set_status("No account connected")
            return
        hidden = self.hidden()
        events = [item for item in self.events if item.calendar.url not in hidden]
        if self.mode == "Month":
            self.draw_month(days, events)
        else:
            self.draw_timeline(days, events)

    def draw_empty(self):
        panel = Qt.QWidget()
        layout = Qt.QVBoxLayout(panel)
        layout.setContentsMargins(20, 20, 20, 20)
        layout.setSpacing(8)
        center = QtCore.Qt.AlignmentFlag.AlignHCenter
        layout.addStretch(1)
        glyph = Qt.QLabel()
        glyph.setPixmap(icon("calendar", self.look.accent, 42).pixmap(42, 42))
        layout.addWidget(glyph, alignment=center)
        layout.addSpacing(7)
        layout.addWidget(label("Connect your calendars", size=21, weight=QtGui.QFont.Weight.DemiBold),
                         alignment=center)
        caption = label("See and edit your iCloud events from this device.", tone="muted", size=13)
        caption.setWordWrap(True)
        caption.setAlignment(center)
        layout.addWidget(caption)
        layout.addSpacing(7)
        connect = button("Connect iCloud", "primary")
        connect.clicked.connect(self.connect_dialog)
        layout.addWidget(connect, alignment=center)
        layout.addStretch(2)
        self.canvas.addWidget(panel, 1)

    def event_button(self, event, caption=""):
        entry = EventButton(event, self.look, compact=True, caption=caption)
        entry.clicked.connect(lambda checked=False: self.open_editor(event))
        return entry

    def draw_day_headers(self, days):
        header = Qt.QWidget()
        row = Qt.QHBoxLayout(header)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(0)
        today = self.now().date()
        columns = []
        for day in days:
            cell = Qt.QWidget()
            day_box = Qt.QVBoxLayout(cell)
            day_box.setContentsMargins(10, 2, 8, 10)
            day_box.setSpacing(4)
            weekday = label(day.strftime("%a"), tone="accent" if day == today else "muted",
                            size=11, weight=QtGui.QFont.Weight.DemiBold)
            day_box.addWidget(weekday)
            date_row = Qt.QHBoxLayout()
            date_button = button(str(day.day), "date", name=day.strftime("%A %-d %B"), size=(30, 29))
            date_button.setProperty("today", day == today)
            font = date_button.font()
            font.setPixelSize(19)
            font.setWeight(QtGui.QFont.Weight.Medium)
            date_button.setFont(font)
            date_button.clicked.connect(lambda checked=False, date=day: self.open_day(date))
            date_row.addWidget(date_button)
            date_row.addStretch()
            day_box.addLayout(date_row)
            columns.append(cell)
        row.addSpacing(GUTTER)
        for cell in columns:
            row.addWidget(cell, 1)
        row.addSpacing(SCROLLBAR)
        self.canvas.addWidget(header)

    def draw_all_day(self, days, events):
        by_day = [[item for item in self.events_on(day, events) if item.all_day] for day in days]
        if not any(by_day):
            return
        area = Qt.QWidget(objectName="allDayRow")
        row = Qt.QHBoxLayout(area)
        row.setContentsMargins(0, 6, 0, 7)
        row.setSpacing(0)
        gutter = label("All day", tone="muted", size=10)
        gutter.setFixedWidth(GUTTER)
        gutter.setAlignment(QtCore.Qt.AlignmentFlag.AlignHCenter | QtCore.Qt.AlignmentFlag.AlignTop)
        gutter.setContentsMargins(0, 6, 0, 0)
        row.addWidget(gutter)
        for day, items in zip(days, by_day):
            lane = Qt.QWidget()
            stack = Qt.QVBoxLayout(lane)
            stack.setContentsMargins(4, 0, 4, 0)
            stack.setSpacing(3)
            for item in items[:2]:
                stack.addWidget(self.event_button(item))
            if len(items) > 2:
                more = button(f"+{len(items) - 2} more")
                more.clicked.connect(lambda checked=False, d=day, rest=items: self.preview(d, rest))
                stack.addWidget(more)
            stack.addStretch()
            row.addWidget(lane, 1)
        row.addSpacing(SCROLLBAR)
        self.canvas.addWidget(area)

    def draw_timeline(self, days, events):
        if len(days) > 1:
            self.draw_day_headers(days)
        self.draw_all_day(days, events)
        payload = [{"id": item.key, "start": item.start.timestamp(), "end": item.end.timestamp(),
                    "notes": item.notes} for item in events if not item.all_day]
        try:
            layout = self.core.call("layout", days=[midnight(day).timestamp() for day in days],
                                    items=payload, now=self.now().timestamp(), adaptive=self.mode == "Day",
                                    pointsPerHour=64 if self.mode == "Week" else 72)
        except CalendarError as error:
            self.canvas.addWidget(label(str(error)), 1)
            return
        area = Qt.QScrollArea(widgetResizable=True)
        area.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOn)
        area.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        area.setWidget(Timeline(self, days, layout, events))
        self.canvas.addWidget(area, 1)
        bar = area.verticalScrollBar()
        if getattr(self, "timeline_scroll", None) is None:
            hour = max(0, min(8, self.now().hour - 1)) if self.now().date() in days else 8
            self.timeline_scroll = round(layout[0]["hours"][min(hour, len(layout[0]["hours"]) - 1)]["top"])
        position = self.timeline_scroll
        QtCore.QTimer.singleShot(0, area, lambda: bar.setValue(position))
        bar.valueChanged.connect(lambda value: setattr(self, "timeline_scroll", value))

    def draw_month(self, days, events):
        container = Qt.QWidget(objectName="monthPage")
        grid = Qt.QGridLayout(container)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setSpacing(0)
        for day in range(7):
            grid.setColumnStretch(day, 1)
            text = label(days[day].strftime("%A"), tone="muted", size=12, weight=QtGui.QFont.Weight.DemiBold)
            text.setContentsMargins(10, 0, 0, 0)
            text.setFixedHeight(31)
            grid.addWidget(text, 0, day)
        today = self.now().date()
        for index, day in enumerate(days):
            row, column = divmod(index, 7)
            grid.setRowStretch(row + 1, 1)
            outside = day.month != self.day.month
            card = Qt.QWidget()
            card.setProperty("monthCell", "today" if day == today else
                             "muted" if outside or day.weekday() >= 5 else "normal")
            card.setSizePolicy(Qt.QSizePolicy.Policy.Ignored, Qt.QSizePolicy.Policy.Preferred)
            card.setMinimumHeight(101)
            box = Qt.QVBoxLayout(card)
            box.setContentsMargins(6, 4, 6, 4)
            box.setSpacing(3)
            items = sorted(self.events_on(day, events), key=lambda item: not item.all_day)
            num = button(str(day.day), "date", name=day.strftime("%A %-d %B"), size=(25, 23))
            num.setSizePolicy(Qt.QSizePolicy.Policy.Fixed, Qt.QSizePolicy.Policy.Fixed)
            num.setProperty("monthNumber", True)
            num.setProperty("outside", outside)
            num.setProperty("today", day == today)
            num.clicked.connect(lambda checked=False, d=day, e=items: self.preview(d, e))
            box.addWidget(num, alignment=QtCore.Qt.AlignmentFlag.AlignLeft)
            for item in items[:2]:
                box.addWidget(self.event_button(item, "" if item.all_day else item.start.strftime("%H:%M")))
            if len(items) > 2:
                more = button(f"+{len(items) - 2} more", "overflow")
                more.clicked.connect(lambda checked=False, d=day, e=items: self.preview(d, e))
                box.addWidget(more)
            box.addStretch()
            grid.addWidget(card, row + 1, column)
        area = Qt.QScrollArea(widgetResizable=True)
        area.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        area.setWidget(container)
        self.canvas.addWidget(area, 1)

    def open_day(self, day):
        self.day = day
        self.change_view("Day")

    def preview(self, day, items):
        dialog = Qt.QDialog(self)
        dialog.setWindowTitle(day.strftime("%A %d %B"))
        dialog.resize(440, 400)
        layout = Qt.QVBoxLayout(dialog)
        layout.setContentsMargins(18, 16, 18, 16)
        layout.setSpacing(12)
        layout.addWidget(label(day.strftime("%A, %-d %B"), size=22, weight=QtGui.QFont.Weight.DemiBold))
        area = Qt.QScrollArea(widgetResizable=True, frameShape=Qt.QFrame.Shape.NoFrame)
        contents = Qt.QWidget()
        rows = Qt.QVBoxLayout(contents)
        rows.setContentsMargins(0, 0, 0, 0)
        if not items:
            rows.addWidget(label("Nothing scheduled", tone="muted"))
        for item in items:
            prefix = "All day" if item.all_day else item.start.strftime("%H:%M")
            rows.addWidget(self.event_button(item, prefix))
        rows.addStretch()
        area.setWidget(contents)
        layout.addWidget(area, 1)
        open_day = button("Open day", "primary")
        open_day.clicked.connect(dialog.accept)
        layout.addWidget(open_day)
        if dialog.exec():
            self.open_day(day)

    def open_editor(self, event=None):
        if not self.store:
            self.connect_dialog()
            return
        choices = (event.calendar,) if event else tuple(c for c in self.calendars if c.writable and c.url not in self.hidden())
        try:
            Editor(self, event, choices).exec()
        except CalendarError as error:
            self.set_status(str(error), "error")


def demo(window):
    today = window.day
    monday = today - timedelta(days=today.weekday())
    sample = [Calendar("demo:work", "Work", "#78aaff", True),
              Calendar("demo:personal", "Personal", "#bd9af8", True),
              Calendar("demo:fitness", "Fitness", "#6bc899", True),
              Calendar("demo:plans", "Plans", "#e8ad69", True)]

    class DemoStore:
        def __init__(self):
            self.records = []
            week = [
                [(9, 15, 65, 0, "Product planning"), (11, 0, 50, 0, "Design review"),
                 (13, 0, 45, 3, "Lunch break"), (15, 30, 70, 2, "Climbing")],
                [(8, 45, 45, 2, "Morning run"), (10, 30, 115, 0, "Focus time"),
                 (14, 0, 65, 1, "Library")],
                [(9, 30, 55, 0, "Team catch-up"), (11, 15, 90, 0, "Prototype workshop"),
                 (11, 45, 90, 1, "Pick up prints"), (15, 0, 55, 3, "Coffee break")],
                [(9, 0, 90, 0, "Write project brief"), (12, 0, 60, 2, "Swimming"),
                 (14, 30, 80, 0, "Client preview")],
                [(8, 30, 70, 2, "Workshop"), (10, 0, 65, 0, "Weekly review"),
                 (13, 30, 100, 0, "Release prep"), (16, 15, 60, 1, "Pick up groceries")],
                [(10, 0, 100, 3, "Market"), (12, 30, 70, 1, "Lunch at home"),
                 (15, 10, 85, 2, "Cycle by the river")],
                [(9, 30, 95, 2, "Park walk"), (12, 0, 80, 3, "Sunday lunch"),
                 (15, 0, 95, 1, "Read and recharge")],
            ]
            for index, entries in enumerate(week):
                day = midnight(monday + timedelta(days=index))
                for hour, minute, duration, calendar, title in entries:
                    start = day + timedelta(hours=hour, minutes=minute)
                    self.save(sample[calendar], Draft(title, start, start + timedelta(minutes=duration), ""))
            friday = monday + timedelta(days=4)
            self.save(sample[0], Draft("Release day", friday, friday + timedelta(days=1), ""))
            self.save(sample[3], Draft("Weekend plans", friday + timedelta(days=1),
                                       friday + timedelta(days=3), ""))
            for offset, name, calendar in [(-12, "Send proposal", 0), (-7, "Dinner with friends", 3),
                                           (8, "Set monthly goals", 1), (13, "5K run", 2)]:
                slot = midnight(today + timedelta(days=offset)) + timedelta(hours=10)
                self.save(sample[calendar], Draft(name, slot, slot + timedelta(hours=1), ""))

        def save(self, calendar, draft, event=None):
            if event:
                self.delete(event)
            key = str(uuid4())
            self.records.append(Event(key, calendar, key, "", draft.title, local_time(draft.start, ZONE),
                                      local_time(draft.end, ZONE), type(draft.start) is date,
                                      draft.notes, b"", True))

        def events(self, calendar, start, end, zone):
            return [event for event in self.records if event.calendar == calendar and
                    event.start < end and event.end > start]

        def delete(self, event):
            self.records.remove(event)

    window.store, window.calendars = DemoStore(), sample
    window.is_demo = True
    window.account.hide()
    window.refresh()


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--core", required=True, type=Path)
    args.add_argument("--demo", action="store_true")
    options = args.parse_args()
    app = Qt.QApplication([sys.argv[0]])
    breeze = next((style for style in Qt.QStyleFactory.keys() if style.lower() == "breeze"), None)
    app.setStyle(breeze or "Fusion")
    app.setOrganizationName("Stillday")
    app.setApplicationName("Calendar")
    window = CalendarWindow(Core(str(options.core.resolve())))
    window.show()
    if options.demo:
        demo(window)
    else:
        QtCore.QTimer.singleShot(0, window.start)
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
