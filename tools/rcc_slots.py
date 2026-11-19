#!/usr/bin/env python3
"""Patch resources inside a Qt 4 .rcc WITHOUT changing its layout.

    rcc_slots.py list BUNDLE.rcc [PATTERN]   show each resource's slot (offset, size)

The unit resumes a Warp snapshot in which qtapp already has the stock bundles mapped,
with the header, tree and name offsets remembered. Pages it has not touched yet are
read from the card later. So a modified bundle must keep every offset identical: the
same length, header, tree and names, and each resource stays in its own slot. A new
resource body is written into the existing slot (its 4-byte length prefix updated,
the rest zero-filled) and must fit. This is how the known-working UI test was built.
"""
import struct
import sys
import zlib


class Entry:
    def __init__(self, path, flags, slot_offset, stored_size):
        self.path, self.flags = path, flags
        self.slot_offset = slot_offset      # absolute offset of the u32 length prefix
        self.stored_size = stored_size      # bytes after the prefix (the slot's capacity)

    @property
    def compressed(self):
        return bool(self.flags & 1)


def parse(data):
    if data[:4] != b"qres":
        raise ValueError("not an rcc file")
    _, version, tree, payload, names = struct.unpack_from(">4sIIII", data)
    node_size = 22 if version >= 2 else 14
    entries = {}

    def name_at(off):
        o = names + off
        n = struct.unpack_from(">H", data, o)[0]
        return data[o + 6:o + 6 + n * 2].decode("utf-16-be")

    def walk(index, prefix):
        n = tree + index * node_size
        name = name_at(struct.unpack_from(">I", data, n)[0]) if index else ""
        flags = struct.unpack_from(">H", data, n + 4)[0]
        path = prefix + "/" + name if prefix else name
        if flags & 2:
            count, first = struct.unpack_from(">II", data, n + 6)
            for i in range(first, first + count):
                walk(i, path)
        else:
            slot = payload + struct.unpack_from(">I", data, n + 10)[0]
            entries[path] = Entry(path, flags, slot, struct.unpack_from(">I", data, slot)[0])

    walk(0, "")
    return entries


def read(data, entry):
    blob = data[entry.slot_offset + 4:entry.slot_offset + 4 + struct.unpack_from(">I", data, entry.slot_offset)[0]]
    return zlib.decompress(blob[4:]) if entry.compressed else blob


def body_for(entry, content):
    """What goes into the slot: qCompress format for compressed resources."""
    if entry.compressed:
        return struct.pack(">I", len(content)) + zlib.compress(content, 9)
    return content


def patch(data, replacements):
    """Return a same-length copy of data with replacements {path: bytes} written into
    their own slots. Raises if anything does not fit; verifies every other resource."""
    entries = parse(data)
    out = bytearray(data)
    for path, content in replacements.items():
        e = entries[path]
        body = body_for(e, content)
        if len(body) > e.stored_size:
            raise ValueError("%s: needs %d bytes, slot holds %d" % (path, len(body), e.stored_size))
        start = e.slot_offset
        out[start:start + 4] = struct.pack(">I", len(body))
        out[start + 4:start + 4 + e.stored_size] = body + b"\0" * (e.stored_size - len(body))
    assert len(out) == len(data)
    check = parse(bytes(out))
    for path, e in entries.items():
        assert check[path].slot_offset == e.slot_offset
        expected = replacements.get(path)
        if expected is None:
            assert read(bytes(out), check[path]) == read(data, e), path
        else:
            assert read(bytes(out), check[path]) == expected, path
    return bytes(out)


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "list":
        sys.exit(__doc__)
    data = open(sys.argv[2], "rb").read()
    pattern = sys.argv[3] if len(sys.argv) > 3 else ""
    for path, e in sorted(parse(data).items()):
        if pattern in path:
            print("%8d  %s  %s" % (e.stored_size, "z" if e.compressed else "-", path))


if __name__ == "__main__":
    main()
