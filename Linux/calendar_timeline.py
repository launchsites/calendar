"""Interactive timed Day and Week canvas."""

from bisect import bisect_left
from datetime import datetime

from PySide6 import QtCore, QtGui, QtWidgets as Qt

from calendar_settings import Buffer
from desktop_style import EventButton, mix


GUTTER = 58
TRACK_PAD = 10
SCROLLBAR = 10
ALIGN = QtCore.Qt.AlignmentFlag.AlignVCenter | QtCore.Qt.AlignmentFlag.AlignLeft


def rect(x, y, width, height):
    return QtCore.QRectF(x, y, max(0, width), max(0, height))


class ActivityCard(EventButton):
    def __init__(self, event, geometry, owner, colors, parent):
        time = owner.preferences.time_label
        caption = f"{time(event.start)} – {time(event.end)}"
        super().__init__(event, owner.look, caption=caption, parent=parent)
        self.geometry_data = geometry
        self.preferences = owner.preferences
        self.before = Buffer(**geometry["before"]) if geometry["before"] else None
        self.after = Buffer(**geometry["after"]) if geometry["after"] else None
        self.markers = [(item["start"], item["end"], colors[item["owner"]])
                        for item in geometry["markers"] if item["owner"] in colors]
        details = [f"{side}: {buffer.summary()}" for side, buffer in (("Before", self.before), ("After", self.after))
                   if buffer]
        if details:
            self.setToolTip(self.toolTip() + "\n" + "\n".join(details))
            self.setAccessibleName(self.toolTip())

    def paintEvent(self, event):
        look = self.styling
        if not self.before and not self.after and not self.markers:
            super().paintEvent(event)
            return
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
        box = rect(0.5, 0.5, self.width() - 1, self.height() - 1)
        path = QtGui.QPainterPath()
        path.addRoundedRect(box, 6, 6)
        first = self.geometry_data["coreTop"]
        last = self.geometry_data["coreBottom"]
        top = min(box.bottom(), max(box.top(), first))
        bottom = min(box.bottom(), max(top, last))
        accent = QtGui.QColor(self.color)
        amt = 0.27 if self.underMouse() else 0.19 if look.dark else 0.13
        fill = QtGui.QColor(mix(accent, look.surface, amt))
        tint = QtGui.QColor(mix(accent, look.surface, amt * 0.5)) if self.preferences.lighter else fill
        p.save()
        p.setClipPath(path)
        p.fillRect(box, tint)
        p.fillRect(rect(box.x(), top, box.width(), bottom - top), fill)
        for start, end, data in ((box.top(), top, self.before), (bottom, box.bottom(), self.after)):
            if data is None or end <= start:
                continue
            self.stripe(p, accent, start, end, dotted=True)
            if end - start >= 17:
                p.setPen(QtGui.QColor(look.text))
                self.text_line(p, start, end - start, "◷  " + data.summary(), 11)

        cursor = top
        for start, end, color in sorted(self.markers):
            start, end = max(top, start), min(bottom, end)
            if end <= start:
                continue
            self.stripe(p, accent, cursor, start, dotted=False)
            self.stripe(p, QtGui.QColor(color), start, end, dotted=True)
            cursor = max(cursor, end)
        self.stripe(p, accent, cursor, bottom, dotted=False)

        h = bottom - top
        if h >= 14:
            p.setPen(QtGui.QColor(look.text))
            self.text_line(p, top + 1, min(h - 2, 21), self.text(), 13, strong=True)
        collapsed = [f"{buf.minutes}m {name}" for name, buf, height in
                     (("before", self.before, top), ("after", self.after, box.bottom() - bottom))
                     if buf and 0 < height < 17]
        if h >= 37:
            p.setPen(QtGui.QColor(look.muted))
            caption = " · ".join(collapsed) if collapsed and h < 52 else self.caption
            self.text_line(p, top + 21, 15, caption, 11)
        if collapsed and h >= 52:
            self.text_line(p, top + 35, 15, " · ".join(collapsed), 10)

        p.restore()
        p.setPen(QtGui.QPen(QtGui.QColor(look.accent if self.hasFocus() else mix(accent, look.surface, 0.27)), 1))
        p.setBrush(QtCore.Qt.BrushStyle.NoBrush)
        p.drawPath(path)

    @staticmethod
    def stripe(painter, color, start, end, *, dotted):
        if end <= start:
            return
        stripe = rect(3.5, start, 3, end - start)
        if not dotted:
            painter.fillRect(stripe, color)
            return
        painter.save()
        painter.setClipRect(stripe, QtCore.Qt.ClipOperation.IntersectClip)
        painter.setPen(QtCore.Qt.PenStyle.NoPen)
        painter.setBrush(color)
        y = start + 1
        while y < end:
            painter.drawEllipse(rect(3.5, y, 3, 3))
            y += 6
        painter.restore()

    def text_line(self, painter, y, height, string, size, strong=False):
        font = self.font()
        font.setPixelSize(size)
        font.setWeight(QtGui.QFont.Weight.DemiBold if strong else QtGui.QFont.Weight.Normal)
        painter.setFont(font)
        width = max(0, self.width() - 19)
        shown = painter.fontMetrics().elidedText(string, QtCore.Qt.TextElideMode.ElideRight, width)
        painter.drawText(rect(12, y, width, height), ALIGN, shown)


class Timeline(Qt.QWidget):
    def __init__(self, owner, days, layout, events, area):
        super().__init__()
        self.owner, self.days, self.track, self.area = owner, days, layout, area
        self.look = owner.look
        self.today = owner.now().date()
        self.zone = owner.now().tzinfo
        self.drag_anchor = None
        self.drag_tip = None
        self.drag_moved = False
        self.drag_pointer = None
        self.setFocusPolicy(QtCore.Qt.FocusPolicy.ClickFocus)
        self.setCursor(QtCore.Qt.CursorShape.CrossCursor)
        self.drag_scroll = QtCore.QTimer(self, interval=25)
        self.drag_scroll.timeout.connect(self.scroll_drag)
        self.snap_tops = [[point["top"] for point in day["snap"]] for day in layout]
        by_key = {event.key: event for event in events}
        colors = {event.key: event.calendar.color for event in events}
        self.setMinimumHeight(int(max(x["height"] for x in layout)) + TRACK_PAD * 2)
        self.setSizePolicy(Qt.QSizePolicy.Policy.Expanding, Qt.QSizePolicy.Policy.Fixed)
        self.cards = []
        for column, data in enumerate(layout):
            for card in sorted(data["cards"], key=lambda item: not item["behind"]):
                event = by_key[card["id"]]
                entry = ActivityCard(event, card, owner, colors, self)
                entry.clicked.connect(lambda checked=False, item=event: self.owner.open_editor(item))
                self.cards.append((column, card, entry))
        self.overlay = TimelineOverlay(self)
        self.overlay.raise_()

    def x(self, column):
        return round(GUTTER + column * (self.width() - GUTTER) / len(self.days))

    def resizeEvent(self, event):
        for column, card, entry in self.cards:
            left = self.x(column + card["leading"]) + 4
            right = self.x(column + card["trailing"]) - 4
            entry.setGeometry(left, round(card["top"]) + TRACK_PAD + 1, max(1, right - left),
                              max(1, round(card["height"]) - 2))
        self.overlay.setGeometry(self.rect())
        super().resizeEvent(event)

    def nearest_slot(self, column, y):
        tops = self.snap_tops[column]
        offset = y - TRACK_PAD
        i = bisect_left(tops, offset)
        if i == len(tops):
            return i - 1
        if i and offset - tops[i - 1] <= tops[i] - offset:
            return i - 1
        return i

    def mousePressEvent(self, event):
        pos = event.position()
        if (event.button() != QtCore.Qt.MouseButton.LeftButton or pos.x() < GUTTER
                or self.width() <= GUTTER
                or not self.owner.writable_calendars()):
            super().mousePressEvent(event)
            return
        column = min(len(self.days) - 1, int((pos.x() - GUTTER) * len(self.days) / (self.width() - GUTTER)))
        if pos.y() > self.snap_tops[column][-1] + TRACK_PAD:
            return
        self.drag_anchor = (column, self.nearest_slot(column, pos.y()))
        self.drag_tip = self.drag_anchor[1]
        self.drag_pointer = event.globalPosition().toPoint()
        self.press_position = self.drag_pointer
        self.drag_scroll.start()
        self.overlay.update()
        event.accept()

    def mouseMoveEvent(self, event):
        if self.drag_anchor is None:
            super().mouseMoveEvent(event)
            return
        self.drag_pointer = event.globalPosition().toPoint()
        if abs(self.drag_pointer.y() - self.press_position.y()) >= Qt.QApplication.startDragDistance():
            self.drag_moved = True
        self.update_drag(event.position().y())
        event.accept()

    def update_drag(self, y):
        column, _ = self.drag_anchor
        slot = self.nearest_slot(column, y)
        if slot != self.drag_tip:
            self.drag_tip = slot
            self.overlay.update()

    def scroll_drag(self):
        if self.drag_anchor is None or not self.drag_moved:
            return
        viewport = self.area.viewport()
        pos = viewport.mapFromGlobal(self.drag_pointer)
        if not 0 <= pos.x() < viewport.width():
            return
        bar = self.area.verticalScrollBar()
        if pos.y() < 24:
            bar.setValue(bar.value() - 10)
        elif pos.y() > viewport.height() - 24:
            bar.setValue(bar.value() + 10)
        self.update_drag(self.mapFromGlobal(self.drag_pointer).y())

    def selection(self):
        if self.drag_anchor is None:
            return None
        column, start = self.drag_anchor
        lo, hi = sorted((start, self.drag_tip))
        if lo == hi:
            return None
        entries = self.track[column]["snap"]
        return column, entries[lo], entries[hi]

    def finish_drag(self):
        self.drag_scroll.stop()
        self.drag_anchor = self.drag_tip = self.drag_pointer = None
        self.drag_moved = False
        self.overlay.update()
        if self.owner.render_pending:
            self.owner.render_pending = False
            QtCore.QTimer.singleShot(0, self.owner, self.owner.render)

    def mouseReleaseEvent(self, event):
        if event.button() != QtCore.Qt.MouseButton.LeftButton or self.drag_anchor is None:
            super().mouseReleaseEvent(event)
            return
        self.update_drag(event.position().y())
        moved = self.drag_moved or abs(event.globalPosition().y() - self.press_position.y()) >= Qt.QApplication.startDragDistance()
        selection = self.selection() if moved else None
        self.finish_drag()
        if selection:
            _, start, end = selection
            dates = tuple(datetime.fromtimestamp(item["time"], self.zone) for item in (start, end))
            QtCore.QTimer.singleShot(0, self.owner, lambda: self.owner.open_editor(selection=dates))
        event.accept()

    def keyPressEvent(self, event):
        if self.drag_anchor is not None and event.key() == QtCore.Qt.Key.Key_Escape:
            self.finish_drag()
            event.accept()
        else:
            super().keyPressEvent(event)

    def paintEvent(self, event):
        p = QtGui.QPainter(self)
        look = self.look
        p.fillRect(event.rect(), QtGui.QColor(look.surface))
        font = self.font()
        font.setPixelSize(11)
        p.setFont(font)
        time = self.owner.preferences.time_label
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
                    p.drawText(QtCore.QRect(0, y - 9, GUTTER - 9, 18),
                               QtCore.Qt.AlignmentFlag.AlignRight | QtCore.Qt.AlignmentFlag.AlignVCenter,
                               time(datetime.fromtimestamp(hour["start"], self.zone)))


class TimelineOverlay(Qt.QWidget):
    def __init__(self, timeline):
        super().__init__(timeline)
        self.timeline = timeline
        self.setAttribute(QtCore.Qt.WidgetAttribute.WA_TransparentForMouseEvents)

    def paintEvent(self, event):
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
        timeline = self.timeline
        look = timeline.look
        accent = QtGui.QColor(look.accent)
        font = self.font()
        font.setPixelSize(11)
        font.setWeight(QtGui.QFont.Weight.DemiBold)
        p.setFont(font)
        selection = timeline.selection()
        time = timeline.owner.preferences.time_label
        if selection:
            column, start, end = selection
            x = timeline.x(column) + 4
            width = timeline.x(column + 1) - x - 4
            top = start["top"] + TRACK_PAD + 1
            height = max(15, end["top"] - start["top"] - 2)
            p.setPen(QtGui.QPen(accent, 1.5))
            p.setBrush(QtGui.QColor(look.selection))
            p.drawRoundedRect(rect(x, top, width, height), 6, 6)
            p.setPen(QtGui.QColor(look.text))
            a, b = (time(datetime.fromtimestamp(point["time"], timeline.zone)) for point in (start, end))
            full = f"{a} – {b}"
            text = full if p.fontMetrics().horizontalAdvance(full) <= width - 12 else a
            p.drawText(rect(x + 6, top + 1, width - 12, min(height, 21)), ALIGN, text)
        for column, day in enumerate(timeline.track):
            if day["now"] is None:
                continue
            y = round(day["now"]) + TRACK_PAD
            left, right = timeline.x(column), timeline.x(column + 1)
            p.setPen(QtGui.QPen(accent, 1.5))
            p.drawLine(left, y, right, y)
            p.setBrush(accent)
            p.drawEllipse(QtCore.QPoint(left, y), 3, 3)
            p.setPen(QtCore.Qt.PenStyle.NoPen)
            p.drawRoundedRect(rect(3, y - 9, GUTTER - 7, 18), 5, 5)
            p.setPen(QtGui.QColor(look.on_accent))
            now = timeline.owner.now()
            p.drawText(rect(3, y - 9, GUTTER - 7, 18), QtCore.Qt.AlignmentFlag.AlignCenter, now.strftime(":%M"))
