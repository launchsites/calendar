"""A reusable grid of month cells with native event and date buttons."""

from datetime import time, timedelta

from PySide6 import QtCore, QtGui, QtWidgets as Qt

from desktop_style import EventButton, button, label


class MonthCell(Qt.QWidget):
    def __init__(self, owner):
        super().__init__()
        self.owner = owner
        self.setAttribute(QtCore.Qt.WidgetAttribute.WA_StyledBackground)
        self.setSizePolicy(Qt.QSizePolicy.Policy.Ignored, Qt.QSizePolicy.Policy.Preferred)
        self.setMinimumHeight(101)
        self.stack = Qt.QVBoxLayout(self)
        self.stack.setContentsMargins(6, 4, 6, 4)
        self.stack.setSpacing(3)
        self.number = button(variant="date", size=(25, 23))
        self.number.setSizePolicy(Qt.QSizePolicy.Policy.Fixed, Qt.QSizePolicy.Policy.Fixed)
        self.number.setProperty("monthNumber", True)
        self.number.clicked.connect(self.preview)
        self.stack.addWidget(self.number, alignment=QtCore.Qt.AlignmentFlag.AlignLeft)
        self.more = button(variant="overflow")
        self.more.clicked.connect(self.preview)
        self.stack.addWidget(self.more)
        self.stack.addStretch()
        self.buttons = []

    def preview(self):
        self.owner.preview(self.day, self.items)

    def show_day(self, day, items, today):
        self.day, self.items = day, items
        outside = day.month != self.owner.day.month
        state = "today" if day == today else "muted" if outside or day.weekday() >= 5 else "normal"
        if self.property("monthCell") != state:
            self.setProperty("monthCell", state)
            self.style().unpolish(self)
            self.style().polish(self)
            self.update()
        self.number.setText(str(day.day))
        self.number.setAccessibleName(day.strftime("%A %-d %B"))
        if self.number.property("outside") != outside or self.number.property("today") != (day == today):
            self.number.setProperty("outside", outside)
            self.number.setProperty("today", day == today)
            self.number.style().unpolish(self.number)
            self.number.style().polish(self.number)
            self.number.update()
        for index, item in enumerate(items[:2]):
            caption = "" if item.all_day else self.owner.preferences.time_label(item.start)
            if index == len(self.buttons):
                entry = EventButton(item, self.owner.look, compact=True, caption=caption)
                entry.clicked.connect(lambda checked=False, i=index: self.owner.open_editor(self.items[i]))
                self.buttons.append(entry)
                self.stack.insertWidget(index + 1, entry)
            else:
                entry = self.buttons[index]
                entry.set_event(item, self.owner.look, caption)
            entry.show()
        for entry in self.buttons[len(items):]:
            entry.hide()
        self.more.setVisible(len(items) > 2)
        if len(items) > 2:
            self.more.setText(f"+{len(items) - 2} more")


class MonthPage(Qt.QScrollArea):
    def __init__(self, owner):
        super().__init__(widgetResizable=True)
        self.owner = owner
        self.month = None
        self.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        container = Qt.QWidget(objectName="monthPage")
        self.grid = Qt.QGridLayout(container)
        self.grid.setContentsMargins(0, 0, 0, 0)
        self.grid.setSpacing(0)
        self.weekdays = []
        for column in range(7):
            self.grid.setColumnStretch(column, 1)
            text = label(tone="muted", size=12, weight=QtGui.QFont.Weight.DemiBold)
            text.setContentsMargins(10, 0, 0, 0)
            text.setFixedHeight(31)
            self.grid.addWidget(text, 0, column)
            self.weekdays.append(text)
        self.cells = []
        self.setWidget(container)

    def set_days(self, days, events, today):
        first, last = days[0], days[-1]
        zone = self.owner.now().tzinfo
        grouped = [[] for _ in days]
        for event in events:
            start, end = event.start.astimezone(zone), event.end.astimezone(zone)
            finish = end.date() - timedelta(days=1) if end > start and end.time() == time.min else end.date()
            a = (max(first, start.date()) - first).days
            b = (min(last, finish) - first).days
            for index in range(a, b + 1):
                grouped[index].append(event)
        for text, day in zip(self.weekdays, days):
            text.setText(day.strftime("%A"))
        for index, (day, items) in enumerate(zip(days, grouped)):
            if index == len(self.cells):
                cell = MonthCell(self.owner)
                row, column = divmod(index, 7)
                self.grid.addWidget(cell, row + 1, column)
                self.cells.append(cell)
            cell = self.cells[index]
            cell.show_day(day, sorted(items, key=lambda item: not item.all_day), today)
            cell.show()
        for cell in self.cells[len(days):]:
            cell.hide()
        for row in range(6):
            self.grid.setRowStretch(row + 1, int(row * 7 < len(days)))
        selected_month = self.owner.day.replace(day=1)
        if self.month != selected_month:
            self.verticalScrollBar().setValue(0)
            self.month = selected_month
