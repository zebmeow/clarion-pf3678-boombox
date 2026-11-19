#!/usr/bin/env python3
"""Resolve qsTrId() ids against an id-based Qt .qm file.
Usage: qm_dump.py file.qm qml_dir  -> prints "ID<TAB>text" for every id used in the QML."""
import os
import re
import sys

data = open(sys.argv[1], "rb").read()
assert data[:16] == bytes.fromhex("3CB86418CAEF9C95CD211CBF60A1BDDD"), "not a qm file"
be = lambda o, n: int.from_bytes(data[o:o + n], "big")

sections, o = {}, 16
while o < len(data):
    tag, ln = data[o], be(o + 1, 4)
    sections[tag] = (o + 5, ln)
    o += 5 + ln

hstart, hlen = sections[0x42]
mstart, _ = sections[0x69]
hashes = {}
for i in range(hstart, hstart + hlen, 8):
    hashes.setdefault(be(i, 4), []).append(be(i + 4, 4))


def translation(off):
    o = mstart + off
    while True:
        tag = data[o]
        o += 1
        if tag == 1:  # end
            return None
        if tag == 3:  # translation
            ln = be(o, 4)
            if ln == 0xFFFFFFFF:
                return None
            return data[o + 4:o + 4 + ln].decode("utf-16-be")
        if tag in (2,):  # obsolete, no payload
            continue
        o += 4 + be(o, 4)  # skip length-prefixed field


def elf_hash(s):
    h = 0
    for c in s.encode():
        h = ((h << 4) + c) & 0xFFFFFFFF
        g = h & 0xF0000000
        if g:
            h ^= g >> 24
        h &= ~g & 0xFFFFFFFF
    return h or 1


ids = set()
for root, _, files in os.walk(sys.argv[2]):
    for f in files:
        if f.endswith((".qml", ".js")):
            ids.update(re.findall(r'qsTrId\("([^"]+)"\)', open(os.path.join(root, f), encoding="utf-8", errors="ignore").read()))

for i in sorted(ids):
    for off in hashes.get(elf_hash(i), []):
        t = translation(off)
        if t is not None:
            print(f"{i}\t{t!r}")
            break
