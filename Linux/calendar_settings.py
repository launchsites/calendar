"""Local calendar display, quick entry, and profile preferences."""

from dataclasses import asdict, dataclass, field
import json
from uuid import uuid4

from PySide6 import QtCore, QtGui, QtWidgets as Qt

from desktop_style import CheckBox, button, label


PURPOSES = ("Travel", "Preparation", "Setup", "Cleanup", "Recovery", "Custom")
TRAVEL_MODES = ("Walking", "Driving", "Train", "Bus", "Cycling", "Flight", "Unspecified")
SNAP_STEPS = (5, 10, 15, 30, 60)


@dataclass
class Buffer:
    minutes: int = 5
    kind: str = "Travel"
    travelMode: str = "Walking"
    label: str = ""

    def summary(self):
        purpose = self.travelMode if self.kind == "Travel" and self.travelMode != "Unspecified" else self.kind
        return f"{self.minutes} min · {self.label or purpose}"


@dataclass
class Profile:
    id: str
    name: str
    calendars: list[str] = field(default_factory=list)
    accent: str = ""


@dataclass
class Preferences:
    week_start: int = 0
    clock: str = "24-hour"
    adaptive: bool = True
    snap: int = 15
    hour_height: int = 72
    all_day: dict[str, bool] = field(default_factory=lambda: {"Day": True, "Week": True, "Month": True})
    month_timed: bool = True
    blend: bool = False
    lighter: bool = False
    entry_mode: str = "schedule"
    duration: int = 60
    default_calendar: str = ""
    before: Buffer = field(default_factory=Buffer)
    after: Buffer = field(default_factory=Buffer)
    profiles: list[Profile] = field(default_factory=list)
    current: str = ""

    @property
    def active_profile(self):
        return next((item for item in self.profiles if item.id == self.current), None)

    @classmethod
    def load(cls, settings):
        try:
            data = json.loads(settings.value("calendarPreferences", "{}", str))
            for key in ("before", "after"):
                if key in data:
                    data[key] = Buffer(**data[key])
            if "profiles" in data:
                data["profiles"] = [Profile(**profile) for profile in data["profiles"]]
            return cls(**data)
        except (TypeError, ValueError):
            return cls()

    def store(self, settings):
        settings.setValue("calendarPreferences", json.dumps(asdict(self)))

    def time_label(self, value):
        return value.strftime("%-I:%M %p" if self.clock == "12-hour" else "%H:%M")


def combo(items, selected):
    field = Qt.QComboBox()
    for title, value in items:
        field.addItem(title, value)
    field.setCurrentIndex(max(0, field.findData(selected)))
    return field


def spin(value, minimum, maximum, suffix=""):
    field = Qt.QSpinBox()
    field.setRange(minimum, maximum)
    field.setValue(value)
    field.setSuffix(suffix)
    return field


def dialog_buttons(dialog, save_text="Save"):
    controls = Qt.QDialogButtonBox(Qt.QDialogButtonBox.StandardButton.Save |
                                   Qt.QDialogButtonBox.StandardButton.Cancel)
    controls.accepted.connect(dialog.accept)
    controls.rejected.connect(dialog.reject)
    save = controls.button(Qt.QDialogButtonBox.StandardButton.Save)
    save.setText(save_text)
    save.setProperty("variant", "primary")
    for control in controls.buttons():
        control.setIcon(QtGui.QIcon())
    return controls


class BufferFields(Qt.QWidget):
    def __init__(self, value, *, allow_label=False):
        super().__init__()
        form = Qt.QFormLayout(self)
        form.setContentsMargins(0, 0, 0, 0)
        form.setVerticalSpacing(8)
        self.minutes = spin(value.minutes, 1, 1440, " min")
        self.kind = combo([(name, name) for name in PURPOSES], value.kind)
        self.travel = combo([(name, name) for name in TRAVEL_MODES], value.travelMode)
        form.addRow("Duration", self.minutes)
        form.addRow("Purpose", self.kind)
        form.addRow("Travel mode", self.travel)
        self.kind.currentIndexChanged.connect(
            lambda: form.setRowVisible(self.travel, self.kind.currentData() == "Travel"))
        form.setRowVisible(self.travel, self.kind.currentData() == "Travel")
        self.caption = None
        if allow_label:
            self.caption = Qt.QLineEdit(value.label)
            self.caption.setPlaceholderText("Optional label")
            form.addRow("Label", self.caption)

    def value(self):
        return Buffer(self.minutes.value(), self.kind.currentData(), self.travel.currentData(),
                      self.caption.text().strip() if self.caption else "")


def edit_buffer(owner, side, value, default):
    dialog = Qt.QDialog(owner)
    dialog.setWindowTitle("Time " + side.lower())
    dialog.setMinimumWidth(380)
    layout = Qt.QVBoxLayout(dialog)
    layout.addWidget(label("Time " + side.lower(), size=21, weight=QtGui.QFont.Weight.DemiBold))
    enabled = CheckBox("Include time " + side.lower(), checked=True)
    layout.addWidget(enabled)
    fields = BufferFields(value or default, allow_label=True)
    enabled.toggled.connect(fields.setEnabled)
    layout.addWidget(fields)
    layout.addWidget(dialog_buttons(dialog))
    if not dialog.exec():
        return value
    return fields.value() if enabled.isChecked() else None


class ProfileEditor(Qt.QDialog):
    def __init__(self, window, profile):
        super().__init__(window)
        self.profile = profile
        self.setWindowTitle("Edit profile" if profile else "New profile")
        self.resize(440, 425)
        view = Qt.QVBoxLayout(self)
        form = Qt.QFormLayout()
        self.name = Qt.QLineEdit(profile.name if profile else "")
        self.accent = profile.accent if profile else ""
        color = button("Choose colour…", "secondary")
        clear = button("Use app accent", "secondary")

        def choose():
            selected = Qt.QColorDialog.getColor(QtGui.QColor(self.accent or window.look.accent),
                                                self, "Profile accent")
            if selected.isValid():
                self.accent = selected.name()
                update_color()

        def update_color():
            color.setText(self.accent or "Choose colour…")

        def reset_color():
            self.accent = ""
            update_color()

        color.clicked.connect(choose)
        clear.clicked.connect(reset_color)
        update_color()
        row = Qt.QHBoxLayout()
        row.addWidget(color)
        row.addWidget(clear)
        form.addRow("Name", self.name)
        form.addRow("Accent", row)
        view.addLayout(form)
        view.addWidget(label("Calendars", size=16, weight=QtGui.QFont.Weight.DemiBold))
        view.addWidget(label("Check calendars to include. Drag them to change their order.", tone="muted"))
        self.calendars = Qt.QListWidget()
        self.calendars.setDragDropMode(Qt.QAbstractItemView.DragDropMode.InternalMove)
        selected = profile.calendars if profile else [item.url for item in window.calendars]
        known = {item.url: item for item in window.calendars}
        for key in dict.fromkeys([*selected, *known]):
            calendar = known.get(key)
            item = Qt.QListWidgetItem(calendar.title if calendar else "Unavailable calendar")
            item.setData(QtCore.Qt.ItemDataRole.UserRole, key)
            if calendar:
                item.setForeground(QtGui.QBrush(QtGui.QColor(window.look.text)))
            item.setCheckState(QtCore.Qt.CheckState.Checked if key in selected else QtCore.Qt.CheckState.Unchecked)
            self.calendars.addItem(item)
        view.addWidget(self.calendars, 1)
        controls = dialog_buttons(self)
        submit = controls.button(Qt.QDialogButtonBox.StandardButton.Save)
        submit.setEnabled(bool(self.name.text().strip()))
        self.name.textChanged.connect(lambda text: submit.setEnabled(bool(text.strip())))
        view.addWidget(controls)

    def result_profile(self):
        included = []
        for i in range(self.calendars.count()):
            item = self.calendars.item(i)
            if item.checkState() == QtCore.Qt.CheckState.Checked:
                included.append(item.data(QtCore.Qt.ItemDataRole.UserRole))
        return Profile(self.profile.id if self.profile else str(uuid4()), self.name.text().strip(),
                       included, self.accent)


class SettingsDialog(Qt.QDialog):
    def __init__(self, owner):
        super().__init__(owner)
        self.owner = owner
        self.values = Preferences.load(owner.settings)
        self.setWindowTitle("Calendar Settings")
        self.resize(585, 535)
        column = Qt.QVBoxLayout(self)
        column.setContentsMargins(16, 16, 16, 14)
        column.addWidget(label("Settings", size=23, weight=QtGui.QFont.Weight.DemiBold))
        self.tabs = Qt.QTabWidget()
        self.tabs.addTab(self.profiles_page(), "Profiles")
        self.tabs.addTab(self.display_page(), "Display")
        self.tabs.addTab(self.timing_page(), "Before && After")
        self.tabs.addTab(self.entry_page(), "Quick Entry")
        column.addWidget(self.tabs, 1)
        column.addWidget(dialog_buttons(self))

    @staticmethod
    def form_page():
        view = Qt.QWidget()
        form = Qt.QFormLayout(view)
        form.setContentsMargins(16, 16, 16, 16)
        form.setSpacing(10)
        return view, form

    def profiles_page(self):
        page = Qt.QWidget()
        view = Qt.QVBoxLayout(page)
        view.setContentsMargins(16, 16, 16, 16)
        view.addWidget(label("Choose which calendars appear together.", tone="muted"))
        self.profile_list = Qt.QListWidget()
        self.profile_list.currentRowChanged.connect(self.profile_selection)
        self.profile_list.itemDoubleClicked.connect(lambda _: self.change_profile())
        view.addWidget(self.profile_list, 1)
        actions = Qt.QHBoxLayout()
        for caption, action in (("Add profile", self.new_profile), ("Edit", self.change_profile),
                                ("Delete", self.remove_profile)):
            control = button(caption, "secondary")
            control.clicked.connect(action)
            actions.addWidget(control)
            if caption == "Edit":
                self.edit_profile = control
            if caption == "Delete":
                self.delete_profile = control
        actions.addStretch()
        view.addLayout(actions)
        self.update_profiles(self.values.current)
        return page

    def profile_selection(self, index):
        if hasattr(self, "edit_profile"):
            self.edit_profile.setEnabled(index > 0)
            self.delete_profile.setEnabled(index > 0)

    def update_profiles(self, selected):
        self.profile_list.clear()
        self.profile_list.addItem("All calendars")
        for profile in self.values.profiles:
            self.profile_list.addItem(profile.name)
        row = next((i for i, profile in enumerate(self.values.profiles, 1) if profile.id == selected), 0)
        self.profile_list.setCurrentRow(row)

    def new_profile(self):
        editor = ProfileEditor(self.owner, None)
        if editor.exec():
            result = editor.result_profile()
            self.values.profiles.append(result)
            self.update_profiles(result.id)

    def change_profile(self):
        row = self.profile_list.currentRow()
        if row <= 0:
            return
        editor = ProfileEditor(self.owner, self.values.profiles[row - 1])
        if editor.exec():
            result = editor.result_profile()
            self.values.profiles[row - 1] = result
            self.update_profiles(result.id)

    def remove_profile(self):
        row = self.profile_list.currentRow()
        if row > 0:
            self.values.profiles.pop(row - 1)
            self.update_profiles("")

    def display_page(self):
        prefs = self.values
        view, form = self.form_page()
        self.appearance = combo([(v, v) for v in ("System", "Light", "Dark")], self.owner.appearance)
        self.week = combo([("Monday", 0), ("Sunday", 6), ("Saturday", 5)], prefs.week_start)
        self.clock = combo([(v, v) for v in ("24-hour", "12-hour")], prefs.clock)
        self.layout_mode = combo([("Adaptive", True), ("Fixed columns", False)], prefs.adaptive)
        self.snap = combo([(f"{step} min", step) for step in SNAP_STEPS], prefs.snap)
        self.height = spin(prefs.hour_height, 44, 140, " px")
        for title, control in (("Appearance", self.appearance), ("Week starts on", self.week),
                               ("Time format", self.clock), ("Day layout", self.layout_mode),
                               ("Drag selection increments", self.snap), ("Timeline hour height", self.height)):
            form.addRow(title, control)
        row = Qt.QHBoxLayout()
        self.all_day = {}
        for mode in ("Day", "Week", "Month"):
            control = CheckBox(mode, checked=prefs.all_day.get(mode, True))
            self.all_day[mode] = control
            row.addWidget(control)
        form.addRow("Show all-day events", row)
        self.month_timed = CheckBox("Show timed events in Month", checked=prefs.month_timed)
        form.addRow("", self.month_timed)
        return view

    def timing_page(self):
        view, form = self.form_page()
        self.before = BufferFields(self.values.before)
        self.after = BufferFields(self.values.after)
        form.addRow(label("Default time before", size=16, weight=QtGui.QFont.Weight.DemiBold))
        form.addRow(self.before)
        form.addRow(label("Default time after", size=16, weight=QtGui.QFont.Weight.DemiBold))
        form.addRow(self.after)
        self.background = combo([("Same as event", False), ("Lighter", True)], self.values.lighter)
        self.blend = CheckBox("Blend before/after portions into overlapping events", checked=self.values.blend)
        form.addRow("Extension background", self.background)
        form.addRow(self.blend)
        return view

    def entry_page(self):
        view, form = self.form_page()
        self.entry_mode = combo([("Schedule ahead", "schedule"), ("Log activity", "log")], self.values.entry_mode)
        self.duration = spin(self.values.duration, 1, 1440, " min")
        calendars = [("Ask me", "")] + [(item.title, item.url) for item in self.owner.calendars if item.writable]
        if self.values.default_calendar and all(key != self.values.default_calendar for _, key in calendars):
            calendars.append(("Unavailable calendar", self.values.default_calendar))
        self.default_calendar = combo(calendars, self.values.default_calendar)
        form.addRow("Default mode", self.entry_mode)
        form.addRow("Default duration", self.duration)
        form.addRow("Default calendar", self.default_calendar)
        return view

    def accept(self):
        p = self.values
        p.week_start = self.week.currentData()
        p.clock = self.clock.currentData()
        p.adaptive = self.layout_mode.currentData()
        p.snap = self.snap.currentData()
        p.hour_height = self.height.value()
        p.all_day = {mode: control.isChecked() for mode, control in self.all_day.items()}
        p.month_timed = self.month_timed.isChecked()
        p.before, p.after = self.before.value(), self.after.value()
        p.lighter, p.blend = self.background.currentData(), self.blend.isChecked()
        p.entry_mode, p.duration = self.entry_mode.currentData(), self.duration.value()
        p.default_calendar = self.default_calendar.currentData()
        row = self.profile_list.currentRow()
        p.current = p.profiles[row - 1].id if row > 0 else ""
        self.owner.preferences = p
        p.store(self.owner.settings)
        self.owner.set_appearance(self.appearance.currentData())
        self.owner.refresh()
        super().accept()
