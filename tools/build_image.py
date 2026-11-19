#!/usr/bin/env python3
"""Build a flashable SD card image with the boombox mods, entirely on macOS.

    python3 tools/build_image.py [--stages eq,ui,debloat,fastbt] [--src IMG] [--out IMG]

Copies the original dump, edits only partition 3 (the ext2 SYSTEM root filesystem)
with e2fsprogs' debugfs, then verifies:
  * e2fsck finds the filesystem clean
  * every file written reads back byte-identical, links point where intended
  * every byte outside partition 3 is identical to the original image

Stages match install.sh: eq (EQ + 10 s nav sleep), ui (boombox screens), debloat (stop
car/media services), fastbt (Bluetooth starts in parallel). Replaced stock files are
kept next to the new ones as *.orig and disabled boot links move to /etc/rcS.d.off, so
`sh install.sh / restore` on the unit still undoes everything.
Requires: brew install e2fsprogs zig
"""
import argparse
import hashlib
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
ROOTFS = os.path.join(PROJECT, "rootfs")
E2FS = "/opt/homebrew/opt/e2fsprogs/sbin"
DEFAULT_SRC = os.path.join(os.path.dirname(PROJECT), "extracted", "clarion-pf3678-golden.img")
DEFAULT_OUT = os.path.join(PROJECT, "build", "boombox.img")
SYSTEM_PARTITION = 3
SECTOR = 512

# Only links after S60: qt.sh (S60) blocks until the Warp snapshot is taken, and resume
# boots start at S61, so earlier services (e.g. S59dtv) never run on normal boots anyway
# and could be part of SystemManager's readiness count that gates the snapshot.
DEBLOAT = ["S61smartphonelink.sh", "S62cdplayer", "S63hdr.psh", "S64initspeech.psh",
           "S65MeterInfo.sh", "S69usbaudio.sh", "S70usbstrage.sh", "S99upcheckapp.sh"]


class Plan:
    """debugfs commands plus what to verify afterwards."""

    def __init__(self, tmp, build_id):
        self.cmds, self.files, self.links, self.gone, self.dirs = [], {}, {}, [], set()
        self.tmp, self.build_id = tmp, build_id
        self.inplace = {}  # path -> new content, written over the file's existing blocks

    def render(self, src):
        """Copy of src with @BUILD@ replaced by this image's build id."""
        out = os.path.join(self.tmp, "render-" + os.path.basename(src))
        with open(src) as fh, open(out, "w") as dst:
            dst.write(fh.read().replace("@BUILD@", self.build_id))
        return out

    def mkdir(self, path):
        if path not in self.dirs:
            self.dirs.add(path)
            self.cmds += ["mkdir %s" % path, "sif %s mode 040755" % path, "sif %s uid 0" % path,
                          "sif %s gid 0" % path]

    def add(self, src, dest, mode):
        """New file; the destination must not exist yet."""
        self.cmds += ["write %s %s" % (src, dest), "sif %s mode 0%o" % (dest, 0o100000 | mode),
                      "sif %s uid 0" % dest, "sif %s gid 0" % dest]
        self.files[dest] = src

    def replace(self, src, dest, mode):
        """Stock file: keep it as dest.orig (same inode) and write the new one."""
        self.cmds += ["ln %s %s.orig" % (dest, dest), "unlink %s" % dest]
        self.add(src, dest, mode)

    def symlink(self, path, target):
        self.cmds.append("symlink %s %s" % (path, target))
        self.links[path] = target

    def disable(self, link):
        """Move a boot link to /etc/rcS.d.off (ln + unlink keeps link counts unchanged)."""
        self.mkdir("/etc/rcS.d.off")
        self.cmds += ["ln /etc/rcS.d/%s /etc/rcS.d.off/%s" % (link, link), "unlink /etc/rcS.d/%s" % link]
        self.gone.append("/etc/rcS.d/" + link)


def stage_base(plan, fs):
    """Always applied. Makes the unit drop a Warp snapshot left over from a different
    system (navi.sh guard + boombox-mark.sh) and leave a report on the FAT partition
    after every boot (boombox-diag.sh), since there is no shell on the unit."""
    init = os.path.join(ROOTFS, "etc", "init.d")
    plan.add(plan.render(os.path.join(init, "boombox-mark.sh")), "/etc/init.d/boombox-mark.sh", 0o755)
    plan.symlink("/etc/rcS.d/S11boombox-mark.sh", "../init.d/boombox-mark.sh")
    plan.add(os.path.join(init, "boombox-diag.sh"), "/etc/init.d/boombox-diag.sh", 0o755)
    plan.symlink("/etc/rcS.d/S99boombox-diag.psh", "../init.d/boombox-diag.sh")

    # navi.sh runs at S62, after the snapshot point, on every boot. A kernel resumed
    # from an old snapshot may still have /etc/init.d cached, so the new script must
    # live in the same inode and blocks: it is written over them, same size.
    stock = os.path.join(plan.tmp, "navi.sh.orig")
    debugfs(fs, "-R", "dump /etc/init.d/navi.sh %s" % stock)
    if b"boombox" in open(stock, "rb").read():
        sys.exit("source image already has a boombox navi.sh; build from the original dump")
    plan.add(stock, "/etc/init.d/navi.sh.orig", 0o755)
    plan.inplace["/etc/init.d/navi.sh"] = open(plan.render(os.path.join(init, "navi.sh")), "rb").read()


def stage_probe(plan, fs):
    """Diagnostics only: stock system, with navi.sh rewritten in place (same inode) to
    record Warp/MTD state to /var/local/probe.txt and PROBE.TXT on the FAT partition."""
    stock = os.path.join(plan.tmp, "navi.sh.orig")
    debugfs(fs, "-R", "dump /etc/init.d/navi.sh %s" % stock)
    if b"boombox" in open(stock, "rb").read():
        sys.exit("source image already has a boombox navi.sh; build from the original dump")
    plan.add(stock, "/etc/init.d/navi.sh.orig", 0o755)
    plan.inplace["/etc/init.d/navi.sh"] = open(os.path.join(ROOTFS, "etc", "init.d", "navi-probe.sh"), "rb").read()


def stage_eq(plan):
    lib = os.path.join(PROJECT, "eq", "out", "libbtaeq.so")
    plan.add(lib, "/usr/local/lib/libbtaeq.so", 0o755)
    share = os.path.join(ROOTFS, "usr", "local", "share", "btaeq")
    for d in ("", "/www", "/www/cgi-bin", "/presets"):
        plan.mkdir("/usr/local/share/btaeq" + d)
    plan.add(os.path.join(share, "www", "cgi-bin", "eq"), "/usr/local/share/btaeq/www/cgi-bin/eq", 0o755)
    for p in sorted(os.listdir(os.path.join(share, "presets"))):
        plan.add(os.path.join(share, "presets", p), "/usr/local/share/btaeq/presets/" + p, 0o644)
    init = os.path.join(ROOTFS, "etc", "init.d")
    plan.replace(os.path.join(init, "phone.sh"), "/etc/init.d/phone.sh", 0o755)
    plan.add(os.path.join(init, "btaeq.sh"), "/etc/init.d/btaeq.sh", 0o755)
    plan.symlink("/etc/rcS.d/S21btaeq.sh", "../init.d/btaeq.sh")


def stage_ui(plan):
    plan.replace(os.path.join(ROOTFS, "etc", "init.d", "qt.sh"), "/etc/init.d/qt.sh", 0o755)
    built = os.path.join(PROJECT, "build", "ui")
    for sub, name in (("qml", "res_qml_files_bf4.rcc"), ("image", "res_image_files_bf4.rcc")):
        plan.replace(os.path.join(built, sub, name), "/usr/local/share/skin/%s/%s" % (sub, name), 0o644)


def stage_debloat(plan):
    for link in DEBLOAT:
        plan.disable(link)
    plan.add(os.path.join(ROOTFS, "etc", "init.d", "usbhost.sh"), "/etc/init.d/usbhost.sh", 0o755)
    plan.symlink("/etc/rcS.d/S69usbhost.sh", "../init.d/usbhost.sh")


def stage_fastbt(plan):
    plan.disable("S99phone.sh")
    plan.symlink("/etc/rcS.d/S62phone.psh", "../init.d/phone.sh")


STAGES = {"eq": stage_eq, "ui": stage_ui, "debloat": stage_debloat, "fastbt": stage_fastbt}


def inode_info(fs, path):
    """(inode number, size, data blocks in file order) for a regular file."""
    stat = debugfs(fs, "-R", "stat %s" % path).stdout
    ino = int(re.search(r"Inode:\s+(\d+)", stat).group(1))
    size = int(re.search(r"Size:\s+(\d+)", stat).group(1))
    blocks = [int(b) for b in debugfs(fs, "-R", "blocks %s" % path).stdout.split()]
    return ino, size, blocks


def write_in_place(fs, path, content, block_size):
    """Overwrite a file's data blocks with content padded to the file's current size."""
    ino, size, blocks = inode_info(fs, path)
    if len(content) > size:
        sys.exit("%s: new content is %d bytes, must fit in %d" % (path, len(content), size))
    pad = size - len(content)
    content += b"" if pad == 0 else (b"\n" if pad == 1 else b"#" + b"-" * (pad - 2) + b"\n")
    with open(fs, "r+b") as fh:
        for i, block in enumerate(blocks):
            chunk = content[i * block_size:(i + 1) * block_size]
            if chunk:
                fh.seek(block * block_size)
                fh.write(chunk)
    return ino, content


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def partition(img, number):
    with open(img, "rb") as fh:
        mbr = fh.read(512)
    if mbr[510:512] != b"\x55\xaa":
        sys.exit("%s: no MBR signature" % img)
    entry = mbr[446 + 16 * (number - 1): 446 + 16 * number]
    start = int.from_bytes(entry[8:12], "little")
    count = int.from_bytes(entry[12:16], "little")
    return start * SECTOR, count * SECTOR


def debugfs(fs, *args, write=False):
    return run([os.path.join(E2FS, "debugfs")] + (["-w"] if write else []) + list(args) + [fs])


def sha256(path, offset=0, length=None):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        fh.seek(offset)
        left = length
        while left is None or left > 0:
            chunk = fh.read(1 << 20 if left is None else min(1 << 20, left))
            if not chunk:
                break
            h.update(chunk)
            if left is not None:
                left -= len(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stages", default="eq,ui", help="comma list of: " + ", ".join(STAGES))
    ap.add_argument("--src", default=DEFAULT_SRC)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--probe", action="store_true", help="stock image + Warp/MTD diagnostics only")
    args = ap.parse_args()
    stages = [] if args.probe else [s for s in args.stages.split(",") if s]
    for s in stages:
        if s not in STAGES:
            sys.exit("unknown stage %s" % s)
    if not os.path.exists(os.path.join(E2FS, "debugfs")):
        sys.exit("needs e2fsprogs: brew install e2fsprogs")

    # build what the stages ship
    if "eq" in stages:
        subprocess.check_call([os.path.join(PROJECT, "eq", "build.sh")], stdout=subprocess.DEVNULL)
    if "ui" in stages:
        subprocess.check_call([sys.executable, os.path.join(HERE, "build_ui.py")], stdout=subprocess.DEVNULL)

    offset, length = partition(args.src, SYSTEM_PARTITION)
    print("source   %s" % args.src)
    print("SYSTEM   partition %d at byte %d, %d MB" % (SYSTEM_PARTITION, offset, length >> 20))

    with tempfile.TemporaryDirectory() as tmp:
        fs = os.path.join(tmp, "system.ext2")
        with open(args.src, "rb") as src, open(fs, "wb") as dst:
            src.seek(offset)
            left = length
            while left:
                chunk = src.read(min(1 << 20, left))
                dst.write(chunk)
                left -= len(chunk)
        label = run([os.path.join(E2FS, "dumpe2fs"), "-h", fs]).stdout
        if "Filesystem volume name:   SYSTEM" not in label:
            sys.exit("partition %d is not the SYSTEM filesystem" % SYSTEM_PARTITION)
        if "Filesystem state:         clean" not in label:
            sys.exit("SYSTEM filesystem is not clean in the source image; refusing to edit")

        build_id = time.strftime("%y%m%d%H%M") + secrets.token_hex(3)
        block_size = int(re.search(r"Block size:\s+(\d+)", label).group(1))
        plan = Plan(tmp, build_id)
        (stage_probe if args.probe else stage_base)(plan, fs)
        for s in stages:
            STAGES[s](plan)
        for path in list(plan.files) + list(plan.links):
            if path in plan.files and not os.path.exists(plan.files[path]):
                sys.exit("missing build output: %s" % plan.files[path])
        script = os.path.join(tmp, "cmds")
        with open(script, "w") as fh:
            fh.write("\n".join(plan.cmds) + "\n")
        result = debugfs(fs, "-f", script, write=True)
        errors = [l for l in (result.stdout + result.stderr).splitlines()
                  if l and not l.startswith(("debugfs ", "debugfs: ", "Allocated inode"))]  # debugfs echoes commands
        if errors:
            sys.exit("debugfs reported:\n  " + "\n  ".join(errors))

        inplace = {}
        for path, content in plan.inplace.items():
            before = inode_info(fs, path)
            ino, padded = write_in_place(fs, path, content, block_size)
            inplace[path] = (before, padded)

        # debugfs leaves summary counters for e2fsck to settle; preen, then demand clean
        run([os.path.join(E2FS, "e2fsck"), "-fp", fs])
        check = run([os.path.join(E2FS, "e2fsck"), "-fn", fs])
        if check.returncode != 0:
            sys.exit("e2fsck not clean after edit:\n" + check.stdout + check.stderr)

        # read everything back
        for dest, src in plan.files.items():
            out = os.path.join(tmp, "readback")
            debugfs(fs, "-R", "dump %s %s" % (dest, out))
            if sha256(out) != sha256(src):
                sys.exit("read-back mismatch: %s" % dest)
            meta = debugfs(fs, "-R", "stat %s" % dest).stdout
            owner = re.search(r"User:\s+(\d+)\s+Group:\s+(\d+)", meta)
            mode = re.search(r"Mode:\s+(0\d+)", meta)
            if not owner or owner.groups() != ("0", "0") or not mode or mode.group(1) not in ("0755", "0644"):
                sys.exit("wrong owner/mode on %s" % dest)
        for path, (before, padded) in inplace.items():
            out = os.path.join(tmp, "readback")
            debugfs(fs, "-R", "dump %s %s" % (path, out))
            if open(out, "rb").read() != padded or inode_info(fs, path) != before:
                sys.exit("in-place write of %s did not keep inode/size/blocks or content" % path)
        for link, target in plan.links.items():
            if target not in debugfs(fs, "-R", "stat %s" % link).stdout:
                sys.exit("symlink %s does not point to %s" % (link, target))
        for path in plan.gone:
            if "File not found" not in debugfs(fs, "-R", "stat %s" % path).stderr:
                sys.exit("%s should have been moved away" % path)

        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        if os.path.exists(args.out):
            os.remove(args.out)
        if run(["cp", "-c", args.src, args.out]).returncode != 0:  # APFS clone: instant, no extra space
            shutil.copyfile(args.src, args.out)
        os.chmod(args.out, 0o644)  # the dump came out of the zip read-only
        with open(fs, "rb") as new, open(args.out, "r+b") as img:
            img.seek(offset)
            shutil.copyfileobj(new, img, 1 << 20)

    size = os.path.getsize(args.src)
    if os.path.getsize(args.out) != size:
        sys.exit("output size differs from source")
    if sha256(args.src, 0, offset) != sha256(args.out, 0, offset) or \
            sha256(args.src, offset + length) != sha256(args.out, offset + length):
        sys.exit("bytes outside the SYSTEM partition changed")

    print("build    %s" % build_id)
    print("stages   %s" % ("probe only" if args.probe else "base, " + ", ".join(stages)))
    print("written  %d files, %d in place, %d links, %d boot links disabled"
          % (len(plan.files), len(plan.inplace), len(plan.links), len(plan.gone)))
    print("checked  e2fsck clean, read-back identical, other partitions untouched")
    print("output   %s" % args.out)
    print("sha256   %s" % sha256(args.out))


if __name__ == "__main__":
    main()
