#!/usr/bin/env python3
"""Combine preview/shots/*.png into one labelled overview: preview/shots/00-overview.png"""
import os
from PySide6.QtCore import QRect, Qt
from PySide6.QtGui import QColor, QFont, QGuiApplication, QImage, QPainter

app = QGuiApplication([])
src = "preview/shots"
files = sorted(f for f in os.listdir(src) if f.endswith(".png") and not f.startswith("00-"))
cols, cw, ch, label, pad = 4, 400, 240, 34, 16
rows = (len(files) + cols - 1) // cols
width, height = cols * (cw + pad) + pad, rows * (ch + label + pad) + pad + 60
sheet = QImage(width, height, QImage.Format_RGB32)
sheet.fill(QColor("#0b0d12"))
p = QPainter(sheet)
p.setRenderHint(QPainter.SmoothPixmapTransform)
font = QFont("Helvetica Neue", 22)
font.setBold(True)
p.setFont(font)
p.setPen(QColor("#f4f6fa"))
p.drawText(QRect(pad, 10, width - 2 * pad, 44), Qt.AlignVCenter, "PF-3678 boombox UI previews")
p.setFont(QFont("Helvetica Neue", 14))
for i, name in enumerate(files):
    r, c = divmod(i, cols)
    x, y = pad + c * (cw + pad), 60 + pad + r * (ch + label + pad)
    p.fillRect(QRect(x, y, cw, ch), QColor("#151a24"))
    img = QImage(os.path.join(src, name)).scaled(cw, ch, Qt.KeepAspectRatio, Qt.SmoothTransformation)
    p.drawImage(x + (cw - img.width()) // 2, y + (ch - img.height()) // 2, img)
    p.setPen(QColor("#a9b1bf"))
    p.drawText(QRect(x, y + ch + 4, cw, label - 6), Qt.AlignLeft | Qt.AlignVCenter,
               name[:-4].replace("-", " "))
p.end()
sheet.save(os.path.join(src, "00-overview.png"))
print("wrote %s/00-overview.png (%d screens)" % (src, len(files)))
