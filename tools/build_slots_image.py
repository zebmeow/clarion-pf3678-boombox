#!/usr/bin/env python3
"""Build a boombox UI image the way that is known to work on the unit.

    python3 tools/build_slots_image.py [--src IMG] [--out IMG]

The unit resumes a Warp snapshot in which qtapp already has the stock UI bundles
mapped. Screens loaded after the resume are read lazily from those mappings, so new
QML shows up as long as every offset in the bundles stays the same. This build:

  * patches resources inside the stock BF4 bundles in their existing slots
    (tools/rcc_slots.py): same length, header, tree, names and offsets
  * writes the patched bundles into the two files' existing data blocks on a copy of
    the dump: no new files, no directory, inode, bitmap or superblock changes, no fsck
  * verifies the files read back, the filesystem metadata is untouched, and every
    changed byte of the whole image lies inside those two files' data blocks

ui/ holds replacements for existing stock QML paths only. Icons (ui/images/bmp_BB_*)
are stored in slots of stock images that only the replaced screens used.

--with-eq adds files on /var (partition 6) and rewrites navi.sh/phone.sh in place.
--with-apps (implies --with-eq) also copies build/fat/APPS (tools/build_wefunk.py) to the
FAT map partition (partition 2, mounted at /media/map by navi.sh after the resume) and
the wfplay player to /var. Both partitions are mounted only after the Warp resume.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import rcc_slots  # noqa: E402

E2FS = "/opt/homebrew/opt/e2fsprogs/sbin"
UI = os.path.join(PROJECT, "ui")
DEFAULT_SRC = os.path.join(os.path.dirname(PROJECT), "extracted", "clarion-pf3678-golden.img")
DEFAULT_OUT = os.path.join(PROJECT, "build", "boombox-ui.img")
GOLDEN_SHA256 = "aad2d9f9e11f3b9c3e574d07e897521cfb3e4ec1b49b32b941b876e6912864d5"
SYSTEM_START, SYSTEM_SECTORS = 6361740, 771120   # partition 3 (SYSTEM, ext2, 1 KiB blocks)
VAR_START, VAR_SECTORS = 7486353, 192717         # partition 6 (BACKUP_AREA = /var, ext3)
FAT_START, FAT_SECTORS = 385560, 5976180         # partition 2 (NAVI_MAP, FAT32, /media/map)
APPS_STAGED = os.path.join(PROJECT, "build", "fat", "APPS")
QML_RCC = "/usr/local/share/skin/qml/res_qml_files_bf4.rcc"
IMAGE_RCC = "/usr/local/share/skin/image/res_image_files_bf4.rcc"

# Stock slots filled with a copy of one of our screens (same QML, different entry
# point): holding the tune knob opens settings/SettingsSoundGraphicScreen.qml.
SLOT_COPIES = {
    "settings/SettingsSoundGraphicScreen.qml": "aha/AhaRadioTopScreen.qml",
}

# Our icon -> stock image slot it is stored in. These source-list icons (SiriusXM,
# Pandora) are used only by the stock source list, which ui/ replaces, so qtapp can
# never have loaded them before the snapshot.
ICON_SLOTS = {
    "bmp_BB_BT": "bmp_SOURCE_SELECT_BTN_ICON_SXM_BNOR",
    "bmp_BB_EQ": "bmp_SOURCE_SELECT_BTN_ICON_SXM_BFLA",
    "bmp_BB_PREV": "bmp_SOURCE_SELECT_BTN_ICON_SXM_BCHK",
    "bmp_BB_NEXT": "bmp_SOURCE_SELECT_BTN_ICON_SXM_BLIM",
    "bmp_BB_PLAY_DARK": "bmp_SOURCE_SELECT_BTN_ICON_PANDORA_BLIM",
    "bmp_BB_PAUSE_DARK": "bmp_SOURCE_SELECT_BTN_ICON_PANDORA_BNOR",
    "bmp_BB_BACK": "bmp_SOURCE_SELECT_BTN_ICON_PANDORA_BFLA",
}


# Stock scripts that run after the snapshot point (S61+) on every boot, rewritten in
# place: same inode, same blocks, same size (padded with a trailing comment).
INPLACE = {
    "/etc/init.d/navi.sh": "rootfs-inplace/etc/init.d/navi.sh",
    "/etc/init.d/phone.sh": "rootfs-inplace/etc/init.d/phone.sh",
}

# New files on /var (BACKUP_AREA). wr_snapshot unmounts it before the snapshot and runs
# e2fsck -y + mount after every resume, so the kernel never holds stale state for it.
VAR_DIRS = ["/local/boombox", "/local/boombox/www", "/local/boombox/www/cgi-bin", "/local/boombox/presets"]


def var_files(with_apps):
    """[(local source, path on /var, mode)]; the CGI is pointed at /var for presets."""
    share = os.path.join(PROJECT, "rootfs", "usr", "local", "share", "btaeq")
    tmp_cgi = os.path.join(tempfile.gettempdir(), "boombox-eq-cgi")
    with open(os.path.join(share, "www", "cgi-bin", "eq")) as fh:
        cgi = fh.read().replace("/usr/local/share/btaeq/presets", "/var/local/boombox/presets")
    with open(tmp_cgi, "w") as fh:
        fh.write(cgi)
    files = [(os.path.join(PROJECT, "eq", "out", lib), "/local/boombox/" + lib, 0o755)
             for lib in ("libbtaeq.so", "libbtaeq-compat.so", "hello.so")]
    files.append((tmp_cgi, "/local/boombox/www/cgi-bin/eq", 0o755))
    for name in ("start.sh", "report.sh"):
        files.append((os.path.join(PROJECT, "rootfs-var", "local", "boombox", name), "/local/boombox/" + name, 0o755))
    for preset in sorted(os.listdir(os.path.join(share, "presets"))):
        files.append((os.path.join(share, "presets", preset), "/local/boombox/presets/" + preset, 0o644))
    if with_apps:
        files.append((os.path.join(PROJECT, "wfplay", "out", "wfplay"), "/local/boombox/wfplay", 0o755))
    return files


def padded_script(src, size):
    data = open(os.path.join(PROJECT, src), "rb").read()
    if len(data) > size:
        sys.exit("%s is %d bytes; the stock file it replaces in place is %d" % (src, len(data), size))
    pad = size - len(data)
    return data + (b"" if pad == 0 else b"\n" if pad == 1 else b"#" + b"-" * (pad - 2) + b"\n")


def build_var(img_path, tmp, with_apps):
    """Add the boombox files to partition 6 of img_path. Returns the files written."""
    start, length = VAR_START * 512, VAR_SECTORS * 512
    fs = os.path.join(tmp, "var.ext3")
    with open(img_path, "rb") as img, open(fs, "wb") as dst:
        img.seek(start)
        dst.write(img.read(length))
    if "BACKUP_AREA" not in run([os.path.join(E2FS, "dumpe2fs"), "-h", fs]).stdout:
        sys.exit("partition 6 is not BACKUP_AREA")
    run([os.path.join(E2FS, "e2fsck"), "-fy", fs])     # journal replay, as the unit does
    files = var_files(with_apps)
    cmds = []
    for d in VAR_DIRS:
        if "File not found" in debugfs(fs, "stat %s" % d).stderr:
            cmds += ["mkdir %s" % d, "sif %s mode 040755" % d, "sif %s uid 0" % d, "sif %s gid 0" % d]
    for src, dest, mode in files:
        if not os.path.exists(src):
            sys.exit("missing %s (run eq/build.sh)" % src)
        cmds += ["rm %s" % dest, "write %s %s" % (src, dest), "sif %s mode 0%o" % (dest, 0o100000 | mode),
                 "sif %s uid 0" % dest, "sif %s gid 0" % dest]
    script = os.path.join(tmp, "var.cmds")
    with open(script, "w") as fh:
        fh.write("\n".join(cmds) + "\n")
    run([os.path.join(E2FS, "debugfs"), "-w", "-f", script, fs])
    run([os.path.join(E2FS, "e2fsck"), "-fy", fs])     # settle counters (the unit does this too)
    if run([os.path.join(E2FS, "e2fsck"), "-fn", fs]).returncode != 0:
        sys.exit("BACKUP_AREA not clean after adding files")
    for src, dest, _ in files:
        out = os.path.join(tmp, "var.readback")
        debugfs(fs, "dump %s %s" % (dest, out))
        if open(out, "rb").read() != open(src, "rb").read():
            sys.exit("read-back mismatch on /var%s" % dest)
    with open(fs, "rb") as new, open(img_path, "r+b") as img:
        img.seek(start)
        shutil.copyfileobj(new, img, 1 << 20)
    return files


def build_fat(img_path, tmp):
    """Copy build/fat/APPS onto partition 2 (FAT32) of img_path. Returns the file count."""
    if not os.path.isdir(APPS_STAGED):
        sys.exit("missing %s (run tools/build_wefunk.py)" % APPS_STAGED)
    start, length = FAT_START * 512, FAT_SECTORS * 512
    fs = os.path.join(tmp, "fat.img")
    with open(img_path, "rb") as img, open(fs, "wb") as dst:
        img.seek(start)
        dst.write(img.read(length))
    env = dict(os.environ, MTOOLS_SKIP_CHECK="1", MTOOLS_NO_VFAT="0")
    if "NAVI_MAP" not in subprocess.run(["minfo", "-i", fs, "::"], capture_output=True, text=True, env=env).stdout:
        sys.exit("partition 2 is not the NAVI_MAP FAT partition")
    subprocess.run(["mdeltree", "-i", fs, "::/APPS"], capture_output=True, env=env)
    if subprocess.run(["mcopy", "-i", fs, "-s", "-Q", "-o", APPS_STAGED, "::/"], capture_output=True, env=env).returncode:
        sys.exit("mcopy to the FAT partition failed (full?)")
    if run(["fsck_msdos", "-n", fs]).returncode != 0:
        sys.exit("FAT partition not clean after copying the apps:\n" + run(["fsck_msdos", "-n", fs]).stdout)
    back = os.path.join(tmp, "fat-readback")
    subprocess.run(["mcopy", "-i", fs, "-s", "-Q", "::/APPS", back], check=True, env=env)
    count = 0
    for dirpath, _, files in os.walk(APPS_STAGED):
        for f in files:
            rel = os.path.relpath(os.path.join(dirpath, f), APPS_STAGED)
            if not os.path.exists(os.path.join(back, rel)) or \
                    sha256_file(os.path.join(back, rel)) != sha256_file(os.path.join(dirpath, f)):
                sys.exit("FAT read-back mismatch: APPS/%s" % rel)
            count += 1
    with open(fs, "rb") as new, open(img_path, "r+b") as img:
        img.seek(start)
        shutil.copyfileobj(new, img, 1 << 20)
    return count


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while chunk := fh.read(4 << 20):
            h.update(chunk)
    return h.hexdigest()


def debugfs(fs, request):
    """Read-only debugfs query (never -w)."""
    return run([os.path.join(E2FS, "debugfs"), "-R", request, fs])


def file_blocks(fs, path):
    """Data blocks in file order, from stat's extent list. (debugfs `blocks` also lists
    the IND/DIND/TIND pointer blocks; writing file data over those would destroy the
    file's block map.)"""
    stat = debugfs(fs, "stat %s" % path).stdout
    size = int(re.search(r"Size:\s+(\d+)", stat).group(1))
    listing = stat.split("BLOCKS:", 1)[1].split("TOTAL:", 1)[0]
    blocks = {}
    for first, last, phys_first, phys_last in re.findall(r"\((\d+)(?:-(\d+))?\):(\d+)(?:-(\d+))?", listing):
        first, phys_first = int(first), int(phys_first)
        count = (int(last) if last else first) - first + 1
        if phys_last and int(phys_last) - phys_first + 1 != count:
            sys.exit("%s: malformed extent in stat output" % path)
        for i in range(count):
            blocks[first + i] = phys_first + i
    expected = (size + 1023) // 1024
    if sorted(blocks) != list(range(expected)):
        sys.exit("%s: data blocks do not cover the file" % path)
    return [blocks[i] for i in range(expected)], size, stat


def ui_replacements():
    """{qrc path: bytes} for every QML file in ui/, icon names mapped to their slots."""
    out = {}
    for dirpath, _, files in os.walk(UI):
        if os.path.relpath(dirpath, UI).startswith("images"):
            continue
        for f in files:
            if f.endswith(".qml"):
                rel = os.path.relpath(os.path.join(dirpath, f), UI)
                text = open(os.path.join(dirpath, f), encoding="utf-8").read()
                for ours, slot in ICON_SLOTS.items():
                    text = text.replace("qrc:/%s\"" % ours, "qrc:/%s\"" % slot)
                left = set(re.findall(r"qrc:/(bmp_BB_\w+)", text))
                if left:
                    sys.exit("%s uses icons without a slot: %s" % (rel, ", ".join(sorted(left))))
                out[rel] = text.encode("utf-8")
    for slot, source in SLOT_COPIES.items():
        out[slot] = out[source]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", default=DEFAULT_SRC)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--with-eq", action="store_true",
                    help="also: EQ backend on /var, in-place navi.sh/phone.sh (Bluetooth at S62)")
    ap.add_argument("--with-apps", action="store_true",
                    help="also (implies --with-eq): APPS/ on the FAT partition, wfplay on /var")
    args = ap.parse_args()
    args.with_eq = args.with_eq or args.with_apps

    if subprocess.call([sys.executable, os.path.join(HERE, "qt4check.py"), UI]) != 0:
        sys.exit("qt4check found problems; not building")
    if sha256_file(args.src) != GOLDEN_SHA256:
        sys.exit("source is not the golden dump (sha256 mismatch)")

    start, length = SYSTEM_START * 512, SYSTEM_SECTORS * 512
    with tempfile.TemporaryDirectory() as tmp:
        fs = os.path.join(tmp, "system.ext2")
        with open(args.src, "rb") as src, open(fs, "wb") as dst:
            src.seek(start)
            dst.write(src.read(length))

        # patch both bundles in their existing slots
        stock = {}
        for path in (QML_RCC, IMAGE_RCC):
            out = os.path.join(tmp, os.path.basename(path))
            debugfs(fs, "dump %s %s" % (path, out))
            stock[path] = open(out, "rb").read()
        qml = ui_replacements()
        icons = {slot: open(os.path.join(UI, "images", ours), "rb").read() for ours, slot in ICON_SLOTS.items()}
        patched = {QML_RCC: rcc_slots.patch(stock[QML_RCC], qml),
                   IMAGE_RCC: rcc_slots.patch(stock[IMAGE_RCC], icons)}
        if args.with_eq:
            subprocess.check_call([os.path.join(PROJECT, "eq", "build.sh")], stdout=subprocess.DEVNULL)
            if args.with_apps:
                subprocess.check_call([os.path.join(PROJECT, "wfplay", "build.sh")], stdout=subprocess.DEVNULL)
            for path, src in INPLACE.items():
                patched[path] = padded_script(src, file_blocks(fs, path)[1])

        # write them into the files' existing data blocks
        layout = {}
        for path, data in patched.items():
            blocks, size, stat = file_blocks(fs, path)
            if len(data) != size:
                sys.exit("%s: patched bundle changed length" % path)
            layout[path] = (blocks, stat)
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        if os.path.exists(args.out):
            os.remove(args.out)
        if run(["cp", "-c", args.src, args.out]).returncode != 0:
            shutil.copyfile(args.src, args.out)
        os.chmod(args.out, 0o644)
        with open(args.out, "r+b") as img:
            for path, data in patched.items():
                for i, block in enumerate(layout[path][0]):
                    img.seek(start + block * 1024)
                    img.write(data[i * 1024:(i + 1) * 1024])

        # verify: contents, untouched metadata, clean fs
        with open(args.out, "rb") as img, open(fs, "wb") as dst:
            img.seek(start)
            dst.write(img.read(length))
        for path, data in patched.items():
            out = os.path.join(tmp, "readback")
            debugfs(fs, "dump %s %s" % (path, out))
            if open(out, "rb").read() != data:
                sys.exit("read-back mismatch: %s" % path)
            if debugfs(fs, "stat %s" % path).stdout != layout[path][1]:
                sys.exit("%s: inode metadata changed" % path)
        if run([os.path.join(E2FS, "e2fsck"), "-fn", fs]).returncode != 0:
            sys.exit("e2fsck -fn not clean")
        var_written = build_var(args.out, tmp, args.with_apps) if args.with_eq else []
        fat_files = build_fat(args.out, tmp) if args.with_apps else 0

    # whole-image diff: every changed byte must be inside the two files' data blocks
    allowed = sorted([(start + b * 1024, start + (b + 1) * 1024)
                      for blocks, _ in layout.values() for b in blocks] +
                     ([(VAR_START * 512, (VAR_START + VAR_SECTORS) * 512)] if args.with_eq else []) +
                     ([(FAT_START * 512, (FAT_START + FAT_SECTORS) * 512)] if args.with_apps else []))
    changed, offset, ai = 0, 0, 0
    with open(args.src, "rb") as a, open(args.out, "rb") as b:
        while chunk := a.read(4 << 20):
            other = b.read(len(chunk))
            if chunk != other:
                for i, (x, y) in enumerate(zip(chunk, other)):
                    if x != y:
                        pos = offset + i
                        while ai < len(allowed) and allowed[ai][1] <= pos:
                            ai += 1
                        if not (ai < len(allowed) and allowed[ai][0] <= pos < allowed[ai][1]):
                            sys.exit("byte %d changed outside the allowed areas" % pos)
                        changed += 1
            offset += len(chunk)
    digest = sha256_file(args.out)
    report = {"source_sha256": GOLDEN_SHA256, "image_sha256": digest, "changed_bytes": changed,
              "qml_resources_replaced": sorted(qml), "icon_slots": ICON_SLOTS,
              "inplace_scripts": sorted(INPLACE) if args.with_eq else [],
              "var_files": [d for _, d, _ in var_written], "fat_apps_files": fat_files}
    with open(os.path.splitext(args.out)[0] + ".json", "w") as fh:
        json.dump(report, fh, indent=2)
    print("replaced  %s" % ", ".join(sorted(qml)))
    print("icons     %d stored in source-list icon slots" % len(icons))
    if args.with_eq:
        print("in place  %s (padded to stock size)" % ", ".join(sorted(INPLACE)))
        print("/var      %d files under /var/local/boombox" % len(var_written))
    if args.with_apps:
        print("FAT       %d files under /media/map/APPS" % fat_files)
    print("checked   same length/offsets, inode metadata untouched, e2fsck -fn clean,")
    print("          %d changed bytes, all inside the edited files' blocks%s"
          % (changed, (" and BACKUP_AREA" if args.with_eq else "") + (" and NAVI_MAP" if args.with_apps else "")))
    print("output    %s" % args.out)
    print("sha256    %s" % digest)


if __name__ == "__main__":
    main()
