#!/usr/bin/env python3
"""Render the boombox UI's flat icons into ui/images (packed into the image bundle).

    .venv/bin/python tools/make_icons.py

Icons are drawn as vector paths at their exact display size, white on transparent, so
they stay crisp on the unit (QtQuick 1 scales images without filtering by default).
Files are named like the stock art (bmp_NAME, no extension) and used as qrc:/bmp_NAME.
"""
import os
import sys

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QGuiApplication, QImage, QPainter, QPainterPath, QPen

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ui", "images")
WHITE = QColor("white")
DARK = QColor("#1b1206")  # theme.accentInk: icons drawn on the amber play button


def canvas(size):
    img = QImage(size, size, QImage.Format_ARGB32_Premultiplied)
    img.fill(Qt.transparent)
    p = QPainter(img)
    p.setRenderHint(QPainter.Antialiasing)
    p.scale(size / 100.0, size / 100.0)  # draw everything on a 100x100 grid
    return img, p


def triangle(path, x, y, w, h):
    path.moveTo(x, y)
    path.lineTo(x + w, y + h / 2)
    path.lineTo(x, y + h)
    path.closeSubpath()


def play(p, color=WHITE):
    path = QPainterPath()
    triangle(path, 30, 20, 50, 60)
    p.fillPath(path, color)


def pause(p, color=WHITE):
    p.setBrush(color)
    p.setPen(Qt.NoPen)
    p.drawRoundedRect(QRectF(26, 20, 16, 60), 4, 4)
    p.drawRoundedRect(QRectF(58, 20, 16, 60), 4, 4)


def next_track(p):
    path = QPainterPath()
    triangle(path, 20, 24, 44, 52)
    p.fillPath(path, WHITE)
    p.setBrush(WHITE)
    p.setPen(Qt.NoPen)
    p.drawRoundedRect(QRectF(66, 24, 12, 52), 3, 3)


def prev_track(p):
    p.translate(100, 0)
    p.scale(-1, 1)
    next_track(p)


def bluetooth(p):
    pen = QPen(WHITE, 8, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
    p.setPen(pen)
    path = QPainterPath(QPointF(30, 32))
    for x, y in ((70, 68), (50, 86), (50, 14), (70, 32), (30, 68)):
        path.lineTo(x, y)
    p.drawPath(path)


def equalizer(p):
    pen = QPen(WHITE, 8, Qt.SolidLine, Qt.RoundCap)
    p.setPen(pen)
    for x, knob in ((25, 62), (50, 34), (75, 54)):
        p.drawLine(QPointF(x, 16), QPointF(x, 84))
    p.setPen(Qt.NoPen)
    p.setBrush(WHITE)
    for x, knob in ((25, 62), (50, 34), (75, 54)):
        p.drawEllipse(QPointF(x, knob), 12, 12)


def back(p):
    pen = QPen(WHITE, 10, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
    p.setPen(pen)
    path = QPainterPath(QPointF(62, 18))
    path.lineTo(30, 50)
    path.lineTo(62, 82)
    p.drawPath(path)


ICONS = {
    # name: (painter function, pixel size)
    "BB_PLAY": (play, 48),
    "BB_PAUSE": (pause, 48),
    "BB_PLAY_DARK": (lambda p: play(p, DARK), 48),
    "BB_PAUSE_DARK": (lambda p: pause(p, DARK), 48),
    "BB_NEXT": (next_track, 40),
    "BB_PREV": (prev_track, 40),
    "BB_BT": (bluetooth, 28),
    "BB_BT_BIG": (bluetooth, 96),
    "BB_EQ": (equalizer, 28),
    "BB_BACK": (back, 32),
}


def main():
    QGuiApplication(sys.argv)
    os.makedirs(OUT, exist_ok=True)
    for name, (draw, size) in ICONS.items():
        img, p = canvas(size)
        draw(p)
        p.end()
        img.save(os.path.join(OUT, "bmp_" + name), "PNG")
    print("wrote %d icons to %s" % (len(ICONS), os.path.relpath(OUT)))


if __name__ == "__main__":
    main()
