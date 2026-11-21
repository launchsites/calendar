"""Small platform-independent symbols for event timing labels."""

from PySide6 import QtCore, QtGui


def symbol(buffer):
    return buffer.travelMode if buffer.kind == "Travel" else buffer.kind


def draw_symbol(painter, name, x, y, size, color):
    painter.save()
    painter.translate(x, y)
    painter.scale(size / 16, size / 16)
    pen = QtGui.QPen(QtGui.QColor(color), 1.35)
    pen.setCapStyle(QtCore.Qt.PenCapStyle.RoundCap)
    pen.setJoinStyle(QtCore.Qt.PenJoinStyle.RoundJoin)
    painter.setPen(pen)
    painter.setBrush(QtCore.Qt.BrushStyle.NoBrush)

    def line(*points):
        painter.drawPolyline(QtGui.QPolygonF([QtCore.QPointF(a, b) for a, b in points]))

    def circle(a, b, r):
        painter.drawEllipse(QtCore.QPointF(a, b), r, r)

    def box(a, b, w, h, radius=1.5):
        painter.drawRoundedRect(QtCore.QRectF(a, b, w, h), radius, radius)

    if name == "Walking":
        circle(9.2, 2.6, 1.35)
        line((5.2, 7.4), (7.7, 5.2), (9.4, 5.6), (11.1, 8), (13, 8))
        line((8.7, 5.7), (7.7, 9.2), (10.5, 11.1), (10.8, 14.1))
        line((7.7, 9.2), (6.2, 12), (4.1, 14.2))
    elif name == "Cycling":
        circle(3.6, 10.9, 2.6)
        circle(12.4, 10.9, 2.6)
        line((3.6, 10.9), (6.2, 7), (9, 10.9), (3.6, 10.9))
        line((9, 10.9), (10.3, 5.1), (12.2, 5.1))
        line((10.3, 5.1), (12.4, 10.9))
        line((5.2, 7), (7.2, 7))
    elif name in ("Bus", "Train"):
        box(3.2, 1.8, 9.6, 10.6, 2)
        line((3.2, 8), (12.8, 8))
        if name == "Train":
            line((8, 2.1), (8, 8))
            line((5.5, 12.5), (3.9, 14.4))
            line((10.5, 12.5), (12, 14.4))
        else:
            line((5.3, 12.6), (5.3, 14))
            line((10.6, 12.6), (10.6, 14))
        circle(5.8, 10.1, 0.55)
        circle(10.2, 10.1, 0.55)
    elif name == "Driving":
        box(2, 7, 12, 5.2, 1.6)
        line((3.5, 7), (5.1, 3.8), (10.9, 3.8), (12.5, 7))
        line((4, 12.2), (4, 14))
        line((12, 12.2), (12, 14))
        line((4.4, 9.5), (5.6, 9.5))
        line((10.4, 9.5), (11.6, 9.5))
    elif name == "Flight":
        line((8, 1.7), (8, 13.6))
        line((2, 9.4), (8, 5.1), (14, 9.4))
        line((5.2, 14.2), (8, 12), (10.8, 14.2))
    elif name == "Preparation":
        box(3.5, 2.1, 9, 11.8)
        line((5.5, 6.2), (7, 7.7), (10.4, 4.9))
        line((5.5, 10.7), (10.4, 10.7))
    elif name == "Setup":
        line((3.1, 12.8), (9.4, 6.5), (9.1, 3.5), (11.2, 1.9), (11.4, 4.6),
             (14, 4.8), (12.3, 7.1), (9.7, 7), (4.4, 14))
    elif name == "Cleanup":
        line((8, 1.8), (9.4, 6.4), (14, 8), (9.4, 9.5), (8, 14.2), (6.5, 9.5),
             (1.9, 8), (6.5, 6.4), (8, 1.8))
    elif name == "Recovery":
        line((8, 13.8), (3.2, 9.4), (2.2, 6.7), (3.5, 4.4), (5.7, 4.4),
             (8, 6.2), (10.3, 4.4), (12.5, 4.4), (13.8, 6.7), (12.8, 9.4), (8, 13.8))
    else:
        circle(8, 8, 5.7)
        line((8, 4.8), (8, 8), (10.5, 9.3))
    painter.restore()


def activity_icon(buffer, color):
    pixmap = QtGui.QPixmap(32, 32)
    pixmap.setDevicePixelRatio(2)
    pixmap.fill(QtCore.Qt.GlobalColor.transparent)
    painter = QtGui.QPainter(pixmap)
    painter.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
    draw_symbol(painter, symbol(buffer), 0, 0, 16, color)
    painter.end()
    return QtGui.QIcon(pixmap)
