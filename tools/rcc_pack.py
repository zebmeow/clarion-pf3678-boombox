#!/usr/bin/env python3
"""Pack a directory into a Qt 4 binary resource (.rcc, format version 1).

Usage: rcc_pack.py src_dir out.rcc

Layout matches what Qt 4.8's rcc writes and QResource reads:
  header  "qres" | version | tree offset | data offset | names offset   (5 x u32 BE)
  data    per file: u32 length + payload (zlib payloads carry qCompress's u32 size prefix)
  names   per name: u16 length + u32 qt_hash + UTF-16BE characters
  tree    14-byte nodes, breadth-first; each directory's children are contiguous
          and sorted by qt_hash, because QResource binary-searches them.
"""
import os
import sys
import zlib

COMPRESS_THRESHOLD = 70  # rcc default: compress when it saves at least 70%


def qt_hash(name):
    h = 0
    for ch in name:
        h = ((h << 4) + ord(ch)) & 0xFFFFFFFF
        h ^= (h & 0xF0000000) >> 23
        h &= 0x0FFFFFFF
    return h


def u16(v):
    return v.to_bytes(2, "big")


def u32(v):
    return v.to_bytes(4, "big")


class Node:
    def __init__(self, name, path=None):
        self.name, self.path, self.children = name, path, []

    @property
    def is_dir(self):
        return self.path is None


def build_tree(root_dir):
    def load(name, path):
        if os.path.isdir(path):
            node = Node(name)
            for entry in os.listdir(path):
                if not entry.startswith("."):
                    node.children.append(load(entry, os.path.join(path, entry)))
            node.children.sort(key=lambda n: qt_hash(n.name))
            return node
        return Node(name, path)
    return load("", root_dir)


def pack(root_dir, out_path):
    root = build_tree(root_dir)

    # breadth-first order gives each directory a contiguous run of children
    order, queue = [], [root]
    while queue:
        node = queue.pop(0)
        order.append(node)
        if node.is_dir:
            queue.extend(node.children)
    index = {id(n): i for i, n in enumerate(order)}

    data, data_off = bytearray(), {}
    names, name_off = bytearray(), {}
    for node in order:
        if node.name and node.name not in name_off:
            name_off[node.name] = len(names)
            names += u16(len(node.name)) + u32(qt_hash(node.name)) + node.name.encode("utf-16-be")
        if not node.is_dir:
            raw = open(node.path, "rb").read()
            packed = u32(len(raw)) + zlib.compress(raw)
            node.compressed = bool(raw) and (len(raw) - len(packed)) * 100 // len(raw) >= COMPRESS_THRESHOLD
            blob = packed if node.compressed else raw
            data_off[id(node)] = len(data)
            data += u32(len(blob)) + blob

    tree = bytearray()
    for node in order:
        name = name_off.get(node.name, 0)
        if node.is_dir:
            first = index[id(node.children[0])] if node.children else 0
            tree += u32(name) + u16(2) + u32(len(node.children)) + u32(first)
        else:
            tree += u32(name) + u16(1 if node.compressed else 0) + u16(0) + u16(1) + u32(data_off[id(node)])

    header_len = 20
    data_start = header_len
    names_start = data_start + len(data)
    tree_start = names_start + len(names)
    with open(out_path, "wb") as out:
        out.write(b"qres" + u32(1) + u32(tree_start) + u32(data_start) + u32(names_start))
        out.write(data)
        out.write(names)
        out.write(tree)


if __name__ == "__main__":
    pack(sys.argv[1], sys.argv[2])
