"""Desktop colours and Qt controls for Calendar."""

from pathlib import Path
import os

from PySide6 import QtCore, QtGui, QtWidgets as Qt


def mix(color, background, amount):
    fg, bg = QtGui.QColor(color), QtGui.QColor(background)
    return QtGui.QColor(*[round(a * amount + b * (1 - amount))
                          for a, b in zip(fg.getRgb()[:3], bg.getRgb()[:3])]).name()


def luminance(value):
    rgb = QtGui.QColor(value).getRgbF()[:3]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb]
    return sum(c * weight for c, weight in zip(linear, (0.2126, 0.7152, 0.0722)))


def contrast(first, second):
    lo, hi = sorted((luminance(first), luminance(second)))
    return (hi + 0.05) / (lo + 0.05)


def kde_colors():
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").lower()
    if not any(name in desktop for name in ("kde", "plasma")):
        return None
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return QtCore.QSettings(str(config / "kdeglobals"), QtCore.QSettings.Format.IniFormat)


def kde_color(settings, key, fallback):
    if settings is not None:
        value = settings.value(key)
        parts = value if isinstance(value, list) else str(value).split(",")
        if len(parts) >= 3:
            try:
                rgb = [int(v) for v in parts[:3]]
                if all(0 <= v <= 255 for v in rgb):
                    return QtGui.QColor(*rgb).name()
            except ValueError:
                pass
    return QtGui.QColor(fallback).name()


class DesktopStyle:
    def __init__(self, appearance):
        app = Qt.QApplication.instance()
        kde = kde_colors() if appearance == "System" else None
        native_dark = app.styleHints().colorScheme() == QtCore.Qt.ColorScheme.Dark
        window = kde_color(kde, "Colors:Window/BackgroundNormal", "#20242a" if native_dark else "#f1f4f7")
        dark = QtGui.QColor(window).lightness() < 128 if appearance == "System" else appearance == "Dark"
        self.window = kde_color(kde, "Colors:Window/BackgroundNormal", "#20242a" if dark else "#f1f4f7")
        self.panel = kde_color(kde, "Colors:Window/BackgroundAlternate", "#24292f" if dark else "#f7f9fb")
        self.surface = kde_color(kde, "Colors:View/BackgroundNormal", "#1c2026" if dark else "#ffffff")
        self.text = kde_color(kde, "Colors:View/ForegroundNormal", "#ebeff5" if dark else "#202a36")
        self.muted = mix(self.text, self.surface, 0.63 if dark else 0.70)
        self.border = mix(self.text, self.surface, 0.14)
        self.grid = mix(self.text, self.surface, 0.095)
        self.hover = mix(self.text, self.panel, 0.08)
        self.weekend = mix(self.panel, self.surface, 0.58)
        self.accent = kde_color(kde, "Colors:Selection/BackgroundNormal", "#62c9fa" if dark else "#0077aa")
        self.on_accent = max(("#101820", "#ffffff"), key=lambda value: contrast(value, self.accent))
        self.selection = mix(self.accent, self.panel, 0.20 if dark else 0.12)
        self.accent_text = self.accent
        for amount in (1.0, 0.85, 0.70, 0.55, 0.40, 0.25, 0.0):
            candidate = mix(self.accent, self.text, amount)
            if contrast(candidate, self.selection) >= 4.5 and contrast(candidate, self.surface) >= 4.5:
                self.accent_text = candidate
                break
        self.today_column = mix(self.accent, self.surface, 0.058)
        self.dark = dark

    def apply(self, window):
        palette = QtGui.QPalette()
        roles = QtGui.QPalette.ColorRole
        for role, value in {
            roles.Window: self.window, roles.WindowText: self.text,
            roles.Base: self.surface, roles.AlternateBase: self.panel,
            roles.Text: self.text, roles.Button: self.panel, roles.ButtonText: self.text,
            roles.Highlight: self.accent, roles.HighlightedText: self.on_accent,
            roles.PlaceholderText: self.muted, roles.Link: self.accent_text,
        }.items():
            palette.setColor(role, QtGui.QColor(value))
        for role in (roles.WindowText, roles.Text, roles.ButtonText):
            palette.setColor(QtGui.QPalette.ColorGroup.Disabled, role, QtGui.QColor(self.muted))
        window.setPalette(palette)
        accent = self.accent
        window.setStyleSheet(f"""
            QMainWindow, QDialog {{ background: {self.window}; color: {self.text}; }}
            QWidget#toolbar {{ background: {self.panel}; border-bottom: 1px solid {self.border}; }}
            QWidget#navigationPane {{ background: {self.panel}; border-right: 1px solid {self.border}; }}
            QWidget#navigationBody {{ background: {self.panel}; }}
            QWidget#content {{ background: {self.surface}; }}
            QWidget#statusBar {{ background: {self.panel}; border-top: 1px solid {self.border}; }}
            QWidget#switcher {{ background: {self.window}; border: 1px solid {self.border}; border-radius: 9px; }}
            QWidget#allDayRow {{ background: {self.panel}; border-bottom: 1px solid {self.grid}; }}
            QWidget#monthPage {{ background: {self.surface}; }}
            QWidget[monthCell="normal"] {{ background: {self.surface}; border-top: 1px solid {self.grid}; border-left: 1px solid {self.grid}; }}
            QWidget[monthCell="muted"] {{ background: {self.weekend}; border-top: 1px solid {self.grid}; border-left: 1px solid {self.grid}; }}
            QWidget[monthCell="today"] {{ background: {self.today_column}; border-top: 1px solid {self.grid}; border-left: 1px solid {self.grid}; }}
            QFrame#separator {{ background: {self.border}; }}
            QLabel {{ border: none; background: transparent; color: {self.text}; }}
            QLabel[tone="muted"] {{ color: {self.muted}; }}
            QLabel[tone="accent"] {{ color: {self.accent_text}; }}
            QPushButton {{ background: {self.panel}; color: {self.text};
                border: 1px solid {self.border}; border-radius: 7px; padding: 6px 12px; min-height: 18px; }}
            QPushButton:hover {{ background: {self.hover}; }}
            QPushButton:pressed {{ background: {self.selection}; }}
            QPushButton:focus {{ border-color: {accent}; }}
            QPushButton:disabled {{ color: {self.muted}; }}
            QPushButton[variant="flat"], QPushButton[variant="nav"], QPushButton[variant="segment"] {{
                background: transparent; border-color: transparent;
            }}
            QPushButton[variant="nav"] {{ padding: 0; min-height: 0; }}
            QPushButton[variant="flat"]:hover, QPushButton[variant="nav"]:hover, QPushButton[variant="segment"]:hover {{
                background: {self.hover};
            }}
            QPushButton[variant="segment"]:checked {{ background: {self.selection}; color: {self.accent_text}; }}
            QPushButton[variant="flat"]:focus, QPushButton[variant="nav"]:focus, QPushButton[variant="segment"]:focus {{
                border-color: {accent};
            }}
            QPushButton[variant="primary"] {{ background: {accent}; color: {self.on_accent}; border-color: {accent}; font-weight: 600; }}
            QPushButton[variant="primary"]:hover {{ background: {mix(self.text, accent, 0.13)}; }}
            QPushButton[variant="primary"]:focus {{ border-color: {self.on_accent}; }}
            QPushButton[variant="date"] {{ padding: 0; min-height: 0; border-radius: 7px;
                background: transparent; border-color: transparent; }}
            QPushButton[variant="overflow"] {{ padding: 0 5px; min-height: 0; text-align: left;
                border-color: transparent; background: transparent; color: {self.muted}; }}
            QPushButton[variant="overflow"]:hover {{ background: {self.hover}; }}
            QPushButton[variant="overflow"]:focus {{ border-color: {accent}; }}
            QPushButton[variant="date"][outside="true"] {{ color: {self.muted}; }}
            QPushButton[variant="date"][inRange="true"] {{ background: {self.selection}; }}
            QPushButton[variant="date"][monthNumber="true"] {{ min-height: 21px; max-height: 21px; }}
            QPushButton[variant="date"]:hover {{ background: {self.hover}; }}
            QPushButton[variant="date"][today="true"] {{ background: {accent}; color: {self.on_accent}; font-weight: 650; }}
            QPushButton[variant="date"]:focus {{ border-color: {accent}; }}
            QPushButton[variant="date"][today="true"]:focus {{ border-color: {self.on_accent}; }}
            QPushButton[eventCard="true"] {{ padding: 0; min-height: 0; border: 0; background: transparent; }}
            QPushButton[eventCard="true"][compact="true"] {{ min-height: 25px; max-height: 25px; }}
            QCheckBox {{ color: {self.text}; spacing: 8px; padding: 5px 2px; }}
            QCheckBox:focus {{ outline: 1px solid {accent}; }}
            QLineEdit, QPlainTextEdit, QComboBox, QDateTimeEdit {{
                background: {self.surface}; color: {self.text}; border: 1px solid {self.border}; border-radius: 7px; padding: 7px 9px;
                selection-background-color: {accent}; selection-color: {self.on_accent};
            }}
            QComboBox, QDateTimeEdit {{ padding-right: 22px; }}
            QLineEdit:focus, QPlainTextEdit:focus, QComboBox:focus, QDateTimeEdit:focus {{ border-color: {accent}; }}
            QMenu {{ background: {self.panel}; border: 1px solid {self.border}; padding: 4px; }}
            QMenu::item {{ padding: 6px 24px 6px 20px; border-radius: 4px; }}
            QMenu::item:selected {{ background: {self.selection}; color: {self.text}; }}
            QScrollArea {{ background: transparent; border: none; }}
            QScrollBar:vertical {{ background: {self.surface}; width: 10px; margin: 0; }}
            QScrollBar::handle:vertical {{ background: {self.border}; min-height: 30px; border: 2px solid {self.surface}; border-radius: 5px; }}
            QScrollBar::handle:vertical:hover {{ background: {self.muted}; }}
            QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ height: 0; }}
            QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {{ background: transparent; }}
        """)


THEME_ICONS = {
    "panel": "sidebar-show", "back": "go-previous", "next": "go-next",
    "add": "list-add", "refresh": "view-refresh",
    "calendar": "view-calendar", "menu": "application-menu",
}


def icon(name, color, size=18):
    themed = QtGui.QIcon.fromTheme(THEME_ICONS[name])
    # The add icon is drawn in the primary button's contrasting foreground.
    if name != "add" and not themed.isNull():
        return themed
    pixmap = QtGui.QPixmap(size * 2, size * 2)
    pixmap.setDevicePixelRatio(2)
    pixmap.fill(QtCore.Qt.GlobalColor.transparent)
    p = QtGui.QPainter(pixmap)
    p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
    p.scale(size / 18, size / 18)
    pen = QtGui.QPen(QtGui.QColor(color), 1.45)
    pen.setCapStyle(QtCore.Qt.PenCapStyle.RoundCap)
    pen.setJoinStyle(QtCore.Qt.PenJoinStyle.RoundJoin)
    p.setPen(pen)
    if name in ("back", "next"):
        direction = 1 if name == "back" else -1
        p.drawPolyline(QtGui.QPolygonF([QtCore.QPointF(9 + direction * 2, 4.5),
                                        QtCore.QPointF(9 - direction * 2, 9),
                                        QtCore.QPointF(9 + direction * 2, 13.5)]))
    elif name == "add":
        p.drawLine(9, 4, 9, 14)
        p.drawLine(4, 9, 14, 9)
    elif name == "panel":
        p.drawRoundedRect(QtCore.QRectF(2.25, 3.3, 13.5, 11.4), 2, 2)
        p.drawLine(QtCore.QPointF(6.65, 3.5), QtCore.QPointF(6.65, 14.5))
    elif name == "calendar":
        p.drawRoundedRect(QtCore.QRectF(2.75, 4, 12.5, 11), 2, 2)
        p.drawLine(3, 7, 15, 7)
        p.drawLine(6, 2, 6, 5)
        p.drawLine(12, 2, 12, 5)
    elif name == "menu":
        for y in (5, 9, 13):
            p.drawLine(3, y, 15, y)
    elif name == "refresh":
        p.drawArc(QtCore.QRectF(3.3, 3.3, 11.4, 11.4), 37 * 16, 300 * 16)
        p.drawPolyline(QtGui.QPolygonF([QtCore.QPointF(11, 5), QtCore.QPointF(15, 5),
                                        QtCore.QPointF(15, 1)]))
    p.end()
    return QtGui.QIcon(pixmap)


class CheckBox(Qt.QCheckBox):
    def __init__(self, text, *, color=None, checked=False):
        super().__init__(text)
        self.swatch = color
        self.setChecked(checked)
        self.setCursor(QtCore.Qt.CursorShape.PointingHandCursor)
        self.setMinimumHeight(26)
        self.setSizePolicy(Qt.QSizePolicy.Policy.Ignored if color else Qt.QSizePolicy.Policy.Preferred,
                           Qt.QSizePolicy.Policy.Fixed)

    def hitButton(self, point):
        return self.rect().contains(point)

    def paintEvent(self, event):
        owner = self.window()
        while owner.parentWidget() is not None:
            owner = owner.parentWidget().window()
        look = owner.look
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
        accent = QtGui.QColor(look.accent)
        base = QtGui.QColor(look.surface)
        text = QtGui.QColor(look.text)
        muted = QtGui.QColor(look.muted)
        if self.underMouse() or self.hasFocus():
            p.setPen(QtGui.QPen(accent, 1) if self.hasFocus() else QtCore.Qt.PenStyle.NoPen)
            p.setBrush(QtGui.QColor(mix(text, base, 0.07)))
            p.drawRoundedRect(QtCore.QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5), 6, 6)
        fill = QtGui.QColor(self.swatch) if self.swatch else accent
        box = QtCore.QRectF(6.5, (self.height() - 14) / 2, 14, 14)
        p.setPen(QtGui.QPen(fill if self.isChecked() else muted, 1))
        p.setBrush(fill if self.isChecked() else base)
        p.drawRoundedRect(box, 3.5, 3.5)
        if self.isChecked():
            tick = max(("#101820", "#ffffff"), key=lambda candidate: contrast(candidate, fill))
            pen = QtGui.QPen(QtGui.QColor(tick), 1.45)
            pen.setCapStyle(QtCore.Qt.PenCapStyle.RoundCap)
            pen.setJoinStyle(QtCore.Qt.PenJoinStyle.RoundJoin)
            p.setPen(pen)
            p.drawPolyline(QtGui.QPolygonF([
                QtCore.QPointF(box.left() + 3.4, box.top() + 7.4),
                QtCore.QPointF(box.left() + 6.0, box.top() + 10),
                QtCore.QPointF(box.left() + 10.4, box.top() + 4.1),
            ]))
        p.setPen(text if self.isEnabled() else muted)
        title = QtCore.QRect(29, 0, max(0, self.width() - 33), self.height())
        p.drawText(title, QtCore.Qt.AlignmentFlag.AlignVCenter,
                   self.fontMetrics().elidedText(self.text(), QtCore.Qt.TextElideMode.ElideRight, title.width()))


def button(text="", variant="flat", *, name=None, size=None):
    result = Qt.QPushButton(text)
    result.setProperty("variant", variant)
    result.setCursor(QtCore.Qt.CursorShape.PointingHandCursor)
    if name:
        result.setAccessibleName(name)
        result.setToolTip(name)
    if size:
        result.setFixedSize(*size)
    return result


def label(text="", *, tone=None, size=None, weight=None):
    result = Qt.QLabel(text)
    result.setTextFormat(QtCore.Qt.TextFormat.PlainText)
    if tone:
        result.setProperty("tone", tone)
    font = result.font()
    if size:
        font.setPixelSize(size)
    if weight:
        font.setWeight(weight)
    result.setFont(font)
    return result


class EventButton(Qt.QPushButton):
    def __init__(self, event, style, *, compact=False, caption="", parent=None):
        super().__init__(event.title, parent)
        self.styling = style
        self.setProperty("eventCard", True)
        self.setProperty("compact", compact)
        self.color = event.calendar.color
        self.compact = compact
        self.caption = caption
        self.setToolTip(event.title + ("\n" + caption if caption else ""))
        self.setAccessibleName(self.toolTip())
        self.setCursor(QtCore.Qt.CursorShape.PointingHandCursor)
        self.setMinimumWidth(0)
        self.setSizePolicy(Qt.QSizePolicy.Policy.Ignored, Qt.QSizePolicy.Policy.Fixed)
        if compact:
            self.setFixedHeight(25)

    def paintEvent(self, event):
        style = self.styling
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
        box = QtCore.QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        color = QtGui.QColor(self.color)
        emphasized = self.underMouse() or self.isDown()
        fill = mix(color, style.surface, (0.29 if style.dark else 0.24) if emphasized else (0.19 if style.dark else 0.13))
        p.setPen(QtGui.QPen(QtGui.QColor(style.accent if self.hasFocus() else mix(color, style.surface, 0.27)), 1))
        p.setBrush(QtGui.QColor(fill))
        p.drawRoundedRect(box, 6, 6)
        p.setPen(QtCore.Qt.PenStyle.NoPen)
        p.setBrush(color)
        height = max(2, min(box.height() - 6, 10)) if self.compact else max(2, box.height() - 8)
        p.drawRoundedRect(QtCore.QRectF(3.5, (box.height() - height) / 2 + 0.5, 3, height), 1.5, 1.5)

        font = self.font()
        font.setPixelSize(12 if self.compact else 13)
        font.setWeight(QtGui.QFont.Weight.DemiBold)
        p.setFont(font)
        fm = p.fontMetrics()
        text_width = max(0, self.width() - 20)
        p.setPen(QtGui.QColor(style.text))
        two_lines = not self.compact and bool(self.caption) and self.height() >= 42
        if two_lines:
            p.drawText(12, 6 + fm.ascent(), fm.elidedText(self.text(), QtCore.Qt.TextElideMode.ElideRight, text_width))
            font.setPixelSize(11)
            font.setWeight(QtGui.QFont.Weight.Normal)
            p.setFont(font)
            p.setPen(QtGui.QColor(style.muted))
            p.drawText(12, 21 + p.fontMetrics().ascent(),
                       p.fontMetrics().elidedText(self.caption, QtCore.Qt.TextElideMode.ElideRight, text_width))
        else:
            start = 12
            if self.compact and self.caption and text_width > 90:
                font.setWeight(QtGui.QFont.Weight.Normal)
                p.setFont(font)
                p.setPen(QtGui.QColor(style.muted))
                p.drawText(start, (self.height() - fm.height()) // 2 + fm.ascent(), self.caption)
                start += p.fontMetrics().horizontalAdvance(self.caption) + 6
                font.setWeight(QtGui.QFont.Weight.DemiBold)
                p.setFont(font)
                p.setPen(QtGui.QColor(style.text))
            title = p.fontMetrics().elidedText(self.text(), QtCore.Qt.TextElideMode.ElideRight,
                                              max(0, self.width() - start - 5))
            p.drawText(start, (self.height() - fm.height()) // 2 + fm.ascent(), title)
