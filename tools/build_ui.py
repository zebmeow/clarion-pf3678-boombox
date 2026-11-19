#!/usr/bin/env python3
"""Build the UI resource bundles for the unit: stock BF4 QML/images with ui/ on top.

    python3 tools/build_ui.py          -> build/ui/qml/res_qml_files_bf4.rcc
                                          build/ui/image/res_image_files_bf4.rcc

They replace the files of the same name in /usr/local/share/skin/ on the SYSTEM
partition (qtapp registers qml/res_qml_files_bf4.rcc and image/res_image_files_bf4.rcc).
Refuses to build when tools/qt4check.py finds Qt 5+/ES6 constructs in ui/.
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import rcc_pack  # noqa: E402

UI = os.path.join(PROJECT, "ui")
STOCK = os.path.join(PROJECT, "stock")
OUT = os.path.join(PROJECT, "build", "ui")


def overlay(stock_dir, ui_dir, dest, skip=()):
    """Copy stock_dir to dest, then ui_dir on top (ui wins). Returns the overridden paths."""
    shutil.copytree(stock_dir, dest)
    replaced, added = [], []
    for dirpath, dirs, files in os.walk(ui_dir):
        dirs[:] = [d for d in dirs if os.path.join(dirpath, d) not in skip]
        for f in files:
            src = os.path.join(dirpath, f)
            rel = os.path.relpath(src, ui_dir)
            target = os.path.join(dest, rel)
            (replaced if os.path.exists(target) else added).append(rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy(src, target)
    return replaced, added


def main():
    if subprocess.call([sys.executable, os.path.join(HERE, "qt4check.py"), UI]) != 0:
        sys.exit("qt4check found problems; not building")

    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(os.path.join(OUT, "qml"))
    os.makedirs(os.path.join(OUT, "image"))
    with tempfile.TemporaryDirectory() as tmp:
        qml_tree = os.path.join(tmp, "qml")
        replaced, added = overlay(os.path.join(STOCK, "qml"), UI, qml_tree,
                                  skip=(os.path.join(UI, "images"),))
        rcc_pack.pack(qml_tree, os.path.join(OUT, "qml", "res_qml_files_bf4.rcc"))
        print("qml:   replaced %s" % ", ".join(sorted(replaced)))
        print("       added    %s" % ", ".join(sorted(added)))

        stock_images = os.path.join(tmp, "stock_images")
        subprocess.check_call([sys.executable, os.path.join(HERE, "rcc_extract.py"),
                               os.path.join(STOCK, "res_image_files_bf4.rcc"), stock_images])
        image_tree = os.path.join(tmp, "image")
        replaced, added = overlay(stock_images, os.path.join(UI, "images"), image_tree)
        rcc_pack.pack(image_tree, os.path.join(OUT, "image", "res_image_files_bf4.rcc"))
        print("image: added    %d icons, replaced %d" % (len(added), len(replaced)))

    for sub in ("qml", "image"):
        for f in os.listdir(os.path.join(OUT, sub)):
            print("built %s/%s (%d bytes)" % (sub, f, os.path.getsize(os.path.join(OUT, sub, f))))


if __name__ == "__main__":
    main()
