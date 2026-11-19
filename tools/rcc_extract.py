#!/usr/bin/env python3
"""Extract a Qt binary .rcc resource file. Usage: rcc_extract.py file.rcc outdir"""
import os
import sys
import zlib

data = open(sys.argv[1], "rb").read()
out = sys.argv[2]
assert data[:4] == b"qres", "not an rcc file"
be = lambda o, n: int.from_bytes(data[o:o + n], "big")
version, tree, payload, names = be(4, 4), be(8, 4), be(12, 4), be(16, 4)
node_size = 22 if version >= 2 else 14


def name_at(off):
    o = names + off
    ln = be(o, 2)
    return data[o + 6:o + 6 + ln * 2].decode("utf-16-be")


def walk(idx, path):
    n = tree + idx * node_size
    name = name_at(be(n, 4)) if idx else ""
    flags = be(n + 4, 2)
    p = os.path.join(path, name)
    if flags & 2:  # directory
        count, first = be(n + 6, 4), be(n + 10, 4)
        for i in range(first, first + count):
            walk(i, p)
    else:
        off = payload + be(n + 10, 4)
        size = be(off, 4)
        blob = data[off + 4:off + 4 + size]
        if flags & 1:  # zlib compressed, 4-byte length prefix
            blob = zlib.decompress(blob[4:])
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as fh:
            fh.write(blob)


walk(0, out)
