#!/usr/bin/env python3
"""Stage the WEFUNK app's content for the card's FAT partition (/media/map/APPS).

    .venv/bin/python tools/build_wefunk.py [--src ~/Downloads/work/mscplr] [--out build/fat]

Reads the scraper's catalog/*.json, art/by-artist/*.jpg and audio/*.mp3 and writes
  OUT/APPS/Apps.qml, OUT/APPS/wefunk/*.qml, Silkscreen.ttf   (from apps/)
  OUT/APPS/wefunk/catalog/index.json   shows, newest first, with 4 art slugs each
  OUT/APPS/wefunk/catalog/N.json       one show: track start times, artist, title, art
  OUT/APPS/wefunk/art/SLUG.jpg         192x192 centre crops (the unit only shows small art)
  OUT/APPS/wefunk/audio/N.mp3          copied as is (wfplay seeks by constant bitrate)
Only shows with an audio file are included. Unchanged files are not rewritten.
"""
import argparse
import filecmp
import json
import os
import shutil
import sys

from PySide6.QtCore import Qt
from PySide6.QtGui import QImage

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART_SIZE = 192


def write_json(path, data):
    text = json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n"
    if os.path.exists(path) and open(path, encoding="utf-8").read() == text:
        return
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def copy_if_changed(src, dst):
    if os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(src) and filecmp.cmp(src, dst, shallow=False):
        return False
    shutil.copyfile(src, dst)
    return True


def crop_art(src, dst):
    if os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src):
        return True
    img = QImage(src)
    if img.isNull():
        return False
    side = min(img.width(), img.height())
    # faces sit in the upper part of most artist photos: crop from the top third
    x = (img.width() - side) // 2
    y = max(0, min((img.height() - side) // 3, img.height() - side))
    img = img.copy(x, y, side, side).scaled(ART_SIZE, ART_SIZE, Qt.IgnoreAspectRatio, Qt.SmoothTransformation)
    return img.save(dst, "JPG", 85)


def track_entry(t, art_ok):
    kind = t.get("kind", "song")
    e = {"ms": t.get("mspos", 0), "k": kind[0]}  # s(ong) / t(alk) / i(ntro)
    if kind == "song":
        e["a"] = t.get("artist_canonical") or t.get("artist") or ""
        e["t"] = t.get("title") or ""
        slug = t.get("artist_slug")
        if slug and slug in art_ok:
            e["art"] = slug
    else:
        e["a"] = "WEFUNK"
        over = t.get("over") or {}
        e["t"] = "talk over %s" % over["title"] if kind == "talk" and over.get("title") else t.get("label", kind)
    return e


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", default=os.path.expanduser("~/Downloads/work/mscplr"))
    ap.add_argument("--out", default=os.path.join(PROJECT, "build", "fat"))
    args = ap.parse_args()

    app = os.path.join(args.out, "APPS", "wefunk")
    for d in ("catalog", "art", "audio"):
        os.makedirs(os.path.join(app, d), exist_ok=True)

    # QML and font from apps/
    src_apps = os.path.join(PROJECT, "apps")
    for dirpath, _, files in os.walk(src_apps):
        for f in files:
            if f.startswith("."):
                continue
            rel = os.path.relpath(os.path.join(dirpath, f), src_apps)
            dst = os.path.join(args.out, "APPS", rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            copy_if_changed(os.path.join(dirpath, f), dst)

    shows = []
    for f in os.listdir(os.path.join(args.src, "catalog")):
        if f.endswith(".json") and f[:-5].isdigit():
            n = int(f[:-5])
            if os.path.exists(os.path.join(args.src, "audio", "%d.mp3" % n)):
                shows.append(json.load(open(os.path.join(args.src, "catalog", f), encoding="utf-8")))
    shows.sort(key=lambda s: -s["shownum"])
    if not shows:
        sys.exit("no shows with audio in %s" % args.src)

    art_ok, art_missing = set(), 0
    for show in shows:
        for t in show["tracks"]:
            slug, local = t.get("artist_slug"), t.get("art_local")
            if not slug or not local or slug in art_ok:
                continue
            if crop_art(os.path.join(args.src, local), os.path.join(app, "art", slug + ".jpg")):
                art_ok.add(slug)
            else:
                art_missing += 1

    index, copied = [], 0
    for show in shows:
        n = show["shownum"]
        tracks = [track_entry(t, art_ok) for t in show["tracks"]]
        mosaic = []
        for t in tracks:
            if t.get("art") and t["art"] not in mosaic:
                mosaic.append(t["art"])
        write_json(os.path.join(app, "catalog", "%d.json" % n), {
            "n": n, "date": show["showdate"], "djs": show.get("personnel", []),
            "desc": show.get("description", ""), "ms": show["mstotal"], "tracks": tracks})
        index.append({"n": n, "date": show["showdate"], "djs": show.get("personnel", []),
                      "ms": show["mstotal"], "songs": sum(1 for t in tracks if t["k"] == "s"),
                      "art": mosaic[:4]})
        copied += copy_if_changed(os.path.join(args.src, "audio", "%d.mp3" % n),
                                  os.path.join(app, "audio", "%d.mp3" % n))
    write_json(os.path.join(app, "catalog", "index.json"), index)

    size = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(os.path.join(args.out, "APPS")) for f in fs)
    print("staged %d shows (%d audio copied), %d artist images (%d unreadable), %.1f MB in %s"
          % (len(shows), copied, len(art_ok), art_missing, size / 1e6, os.path.join(args.out, "APPS")))


if __name__ == "__main__":
    main()
