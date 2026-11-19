#!/usr/bin/env python3
"""Preview the head unit's Qt 4 / QtQuick 1.1 UI on a desktop with Qt 6 (PySide6).

    preview.py SCREEN [--shot out.png] [--scenario NAME] [--watch]

SCREEN is a qrc-style path such as btaudio/BtAudioTopScreen.qml. Files in ../ui
override the stock QML (../stock/qml) at the same path, exactly as they will in the
repacked resource bundle on the unit. Apps that live on the card's FAT partition
(../apps -> /media/map/APPS) are SCREENs under APPS/, e.g. APPS/wefunk/Main.qml; they
need tools/build_wefunk.py's staged content and the host wfplay (wfplay/build.sh).

How it bridges the two worlds:
  * every QML/JS file is copied to preview/.build with QtQuick 1.x / ClarionQt imports
    rewritten, and qrc:/*.qml references pointed at the build tree
  * Clarion enum holders (ScreenMgr.RUNTIME_SCREEN_WIDTH, CSoundUtility.BEEPKIND_UP, ...)
    are replaced with stable numbers; the unit's real values do not matter for layout
  * the 71 my* context objects and the C++ visual types (BasicLabel, CBufferImage, ...)
    are generated as mocks from how the QML uses them; scenarios/NAME.json sets values
  * the real image bundle and US English strings are loaded, so stock art and text show

What it cannot tell you: anything about Qt 4.8's runtime behaviour. Run
tools/qt4check.py on ui/ to catch Qt Quick 2-only syntax before it reaches the unit.
"""
import argparse
import json
import os
import re
import shutil
import sys
import threading

from PySide6.QtCore import QFileSystemWatcher, QObject, QResource, QTimer, QTranslator, QUrl, Slot
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlComponent, QQmlEngine
from PySide6.QtQuick import QQuickView, QQuickWindow, QSGRendererInterface

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
STOCK_QML = os.path.join(PROJECT, "stock", "qml")
UI_DIR = os.path.join(PROJECT, "ui")
APPS_DIR = os.path.join(PROJECT, "apps")                  # /media/map/APPS on the unit
APPS_STAGED = os.path.join(PROJECT, "build", "fat", "APPS")
CARD_APPS_URL = "file:///media/map/APPS/"
WFPLAY = os.path.join(PROJECT, "wfplay", "out", "wfplay-host")
IMAGES_RCC = os.path.join(PROJECT, "stock", "res_image_files_bf4.rcc")
STRINGS_QM = os.path.join(PROJECT, "stock", "res_language_us_gen_bf4.qm")
BUILD = os.path.join(HERE, ".build")
MOCK_MODULE = "ClarionMock"
# The unit renders DFHei-Nissan-P (DynaComware's FDL format, via a patched FreeType),
# which desktop Qt cannot load; Helvetica Neue is a close-enough gothic sans for layout.
PREVIEW_FONT = "Helvetica Neue"

# Capitalised names that belong to Qt, not to the Clarion C++ side
QT_NAMES = {
    "Qt", "Text", "Image", "Loader", "ListView", "GridView", "Flickable", "Math", "Keys",
    "Font", "TextEdit", "TextInput", "PathView", "Easing", "Component", "Item", "BorderImage",
    "AnimatedImage", "Flow", "Grid", "MouseArea", "Positioner", "XmlListModel", "Date",
    "Number", "String", "JSON", "Array", "Object", "StateGroup", "Flipable", "Repeater",
    "Row", "Column", "Rectangle", "Timer", "ListModel", "Connections", "Drag", "Animation",
}

ENUM_OVERRIDES = {
    ("ScreenMgr", "RUNTIME_SCREEN_WIDTH"): 800,
    ("ScreenMgr", "RUNTIME_SCREEN_HEIGHT"): 480,
}

# C++ visual types from the ClarionQt plugin, mocked on top of a QtQuick base type
VISUAL_MOCKS = {
    "BasicLabel": "Text", "BasicListLabel": "Text", "CBufferImage": "Image",
    "ArtworkImage": "Image", "CPandoraArtwork": "Image", "CSXMChannelLogo": "Image",
    "CAhaImage": "Image", "CameraGuideLine": "Item",
}


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def blocks(text, type_name):
    """Yield the body of every `type_name { ... }` block (brace matched)."""
    for m in re.finditer(r"\b%s\s*\{" % re.escape(type_name), text):
        depth, i = 1, m.end()
        while i < len(text) and depth:
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        yield text[m.end():i - 1]


def top_level(body):
    """The part of a block body at nesting depth 0 (drops nested child objects)."""
    out, depth = [], 0
    for ch in body:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        elif depth == 0:
            out.append(ch)
    return "".join(out)


class Scan:
    """Everything the QML expects from the C++ side, collected from source text."""

    def __init__(self, sources):
        self.enums = {}       # holder -> set(names)
        self.objects = {}     # myX -> {"props": set, "methods": set, "signals": set}
        self.visual_props = {name: set() for name in VISUAL_MOCKS}
        qml_types = {os.path.splitext(os.path.basename(p))[0] for p in sources}
        # some "my..." names are plain QML ids, not C++ context objects
        qml_ids = set()
        for text in sources.values():
            qml_ids.update(re.findall(r"\bid\s*:\s*([A-Za-z_][A-Za-z0-9_]*)", text))

        for path, text in sources.items():
            for holder, name in re.findall(r"\b([A-Z][A-Za-z0-9]*)\.([A-Z][A-Z0-9_]*)\b", text):
                if holder not in QT_NAMES and holder not in qml_types:
                    self.enums.setdefault(holder, set()).add(name)
            for obj, member, call in re.findall(r"\b(my[A-Z][A-Za-z0-9]*)\.([a-z_][A-Za-z0-9_]*)\s*(\()?", text):
                if obj in qml_ids:
                    continue
                entry = self.objects.setdefault(obj, {"props": set(), "methods": set(), "signals": set()})
                (entry["methods"] if call else entry["props"]).add(member)
            for body in blocks(text, "Connections"):
                target = re.search(r"target\s*:\s*(my[A-Z][A-Za-z0-9]*)", body)
                if target and target.group(1) not in qml_ids:
                    entry = self.objects.setdefault(target.group(1), {"props": set(), "methods": set(), "signals": set()})
                    for handler in re.findall(r"\bon([A-Z][A-Za-z0-9_]*)\s*:", top_level(body)):
                        entry["signals"].add(handler[0].lower() + handler[1:])
            for name in VISUAL_MOCKS:
                for body in blocks(text, name):
                    self.visual_props[name].update(
                        re.findall(r"(?:^|[\n;])\s*([a-z][A-Za-z0-9_]*)\s*:", top_level(body)))

        for entry in self.objects.values():
            # a "changed" signal that matches a property is provided by the property itself
            entry["signals"] = {s for s in entry["signals"]
                                if not (s.endswith("Changed") and s[:-7] in entry["props"])}
            entry["props"] -= entry["methods"]

        self.enum_values = {}
        n = 1000
        for holder in sorted(self.enums):
            for name in sorted(self.enums[holder]):
                self.enum_values[(holder, name)] = ENUM_OVERRIDES.get((holder, name), n)
                n += 1


def default_value(prop):
    p = prop.lower()
    if re.match(r"^(b[A-Z]|is|has|can)", prop) or p.endswith(("enable", "enabled", "visible", "exist", "existence")):
        return False
    if any(k in p for k in ("title", "text", "name", "str", "url", "path", "label", "number")):
        return ""
    if "list" in p and not p.endswith(("index", "count", "num", "type")):
        return []
    return 0


def method_return(method):
    """Plausible return value for a mocked C++ getter, so bindings get real types."""
    m = method.lower()
    if not m.startswith(("get", "is", "has", "have", "can")):
        return None
    if "color" in m:
        return "#ffffff"
    if "fontname" in m or "family" in m:
        return PREVIEW_FONT
    if m.startswith(("is", "has", "have", "can")):
        return False
    if any(k in m for k in ("size", "height", "width")):
        return 24
    if any(k in m for k in ("text", "name", "title", "str", "family")):
        return ""
    return 0


def resolve(value, scan):
    """Scenario values like "@CBTAudioControl.STREAM_STATE_ON" -> the preview's enum number."""
    if isinstance(value, str) and value.startswith("@"):
        holder, _, name = value[1:].partition(".")
        if (holder, name) not in scan.enum_values:
            sys.exit("scenario: unknown enum %s" % value)
        return scan.enum_values[(holder, name)]
    return value


def transform(text, scan, build_dir):
    text = re.sub(r"^import\s+QtQuick\s+1\.\d+\s*$", "import QtQuick", text, flags=re.M)
    text = re.sub(r"^import\s+ClarionQt\s+1\.\d+\s*$", "import %s" % MOCK_MODULE, text, flags=re.M)
    # QtQuick 1 animations emitted completed(); Qt Quick 2 calls it finished()
    text = re.sub(r"(?<![.\w])onCompleted(\s*:)", r"onFinished\1", text)

    def enum(m):
        value = scan.enum_values.get((m.group(1), m.group(2)))
        return str(value) if value is not None else m.group(0)
    text = re.sub(r"\b([A-Z][A-Za-z0-9]*)\.([A-Z][A-Z0-9_]*)\b", enum, text)
    text = text.replace(CARD_APPS_URL, QUrl.fromLocalFile(os.path.join(build_dir, "APPS")).toString() + "/")
    # qrc:/dir/File.qml -> the transformed copy in the build tree (images stay in qrc)
    text = re.sub(r"qrc:/([A-Za-z0-9_/]+\.(?:qml|js))",
                  lambda m: QUrl.fromLocalFile(os.path.join(build_dir, m.group(1))).toString(), text)
    return text


def write_mocks(scan, base_props, scenario):
    module = os.path.join(BUILD, MOCK_MODULE)
    os.makedirs(module, exist_ok=True)
    qmldir = ["module %s" % MOCK_MODULE, "VisualItemModel 1.0 VisualItemModel.qml"]
    with open(os.path.join(module, "VisualItemModel.qml"), "w") as fh:
        fh.write("import QtQml.Models\nObjectModel {}\n")

    for name, base in VISUAL_MOCKS.items():
        extra = sorted(scan.visual_props[name] - base_props[base])
        lines = ["import QtQuick", "%s {" % base]
        if base == "Text":
            lines += ['    color: "white"', "    font.pixelSize: 24", "    elide: Text.ElideRight",
                      "    verticalAlignment: Text.AlignVCenter"]
        lines += ["    property var %s" % p for p in extra if p != "fontTableId"]
        lines += ["    property int fontTableId", "}"]
        with open(os.path.join(module, name + ".qml"), "w") as fh:
            fh.write("\n".join(lines) + "\n")
        qmldir.append("%s 1.0 %s.qml" % (name, name))

    with open(os.path.join(module, "qmldir"), "w") as fh:
        fh.write("\n".join(qmldir) + "\n")

    out = ["import QtQuick", "QtObject {", "    id: mocks", "    signal called(string what, var args)"]
    # scenario lists of objects become ListModels (C++ list models such as myDeviceListModel)
    for name, rows in scenario.get("models", {}).items():
        out.append("    property QtObject %s: ListModel {" % name)   # QtObject: PySide has no ListModel converter
        for row in rows:
            out.append("        ListElement { %s }" % "; ".join("%s: %s" % (k, json.dumps(v)) for k, v in row.items()))
        out.append("    }")
    for obj in sorted(scan.objects):
        entry = scan.objects[obj]
        values = scenario.get(obj, {})
        out.append("    property QtObject %s: QtObject {" % obj)
        for prop in sorted(entry["props"] | set(values)):
            value = resolve(values.get(prop, default_value(prop)), scan)
            out.append("        property var %s: %s" % (prop, json.dumps(value)))
        for sig in sorted(entry["signals"]):
            out.append("        signal %s()" % sig)
        for method in sorted(entry["methods"]):
            ret = method_return(method)
            if ret is None:
                out.append("        function %s() { mocks.called(\"%s.%s\", Array.prototype.slice.call(arguments)) }"
                           % (method, obj, method))
            else:
                out.append("        function %s() { return %s }" % (method, json.dumps(ret)))
        out.append("    }")
    out.append("}")
    with open(os.path.join(BUILD, "Mocks.qml"), "w") as fh:
        fh.write("\n".join(out) + "\n")


def base_type_props(engine):
    """Property names QtQuick's Text/Image/Item already have (must not be redeclared)."""
    props = {}
    for base in ("Text", "Image", "Item"):
        comp = QQmlComponent(engine)
        comp.setData(("import QtQuick\n%s {}" % base).encode(), QUrl())
        obj = comp.create()
        mo = obj.metaObject()
        props[base] = {mo.property(i).name() for i in range(mo.propertyCount())}
        obj.deleteLater()
    return props


def build(engine, scenario):
    sources = {}
    for root in (STOCK_QML, UI_DIR):
        if not os.path.isdir(root):
            continue
        for dirpath, _, files in os.walk(root):
            for f in files:
                if f.endswith((".qml", ".js")):
                    rel = os.path.relpath(os.path.join(dirpath, f), root)
                    sources[rel] = read(os.path.join(dirpath, f))  # ui/ wins over stock
    for dirpath, _, files in os.walk(APPS_DIR):
        for f in files:
            if f.endswith((".qml", ".js")):
                rel = os.path.relpath(os.path.join(dirpath, f), APPS_DIR)
                sources[os.path.join("APPS", rel)] = read(os.path.join(dirpath, f))

    # slots the image build fills with copies of our screens (tools/build_slots_image.py)
    sys.path.insert(0, os.path.join(PROJECT, "tools"))
    from build_slots_image import SLOT_COPIES
    for slot, source in SLOT_COPIES.items():
        if source in sources:
            sources[slot] = sources[source]
    scan = Scan(sources)
    shutil.rmtree(BUILD, ignore_errors=True)
    for rel, text in sources.items():
        dest = os.path.join(BUILD, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(transform(text, scan, BUILD))
    write_mocks(scan, base_type_props(engine), scenario)
    link_app_files()
    return scan


def link_app_files():
    """Fonts and staged content (art, catalog) next to the transformed app QML."""
    for base in (APPS_DIR, APPS_STAGED):
        for dirpath, dirs, files in os.walk(base):
            rel = os.path.relpath(dirpath, base)
            if rel.split(os.sep)[-1] in ("art", "catalog", "audio"):
                dest = os.path.join(BUILD, "APPS", rel)
                if not os.path.exists(dest):
                    os.makedirs(os.path.dirname(dest), exist_ok=True)
                    os.symlink(dirpath, dest)
                dirs[:] = []
                continue
            for f in files:
                dest = os.path.join(BUILD, "APPS", rel, f)
                if not f.endswith((".qml", ".js")) and not os.path.exists(dest):
                    os.makedirs(os.path.dirname(dest), exist_ok=True)
                    os.symlink(os.path.join(dirpath, f), dest)


def start_wfplay(calls):
    """Run the real player service (silent output) on 127.0.0.1:8089 for app previews,
    then make the scenario's API calls, e.g. ["/play?show=1198&pos=1500000"]."""
    import subprocess
    import time
    import urllib.request
    root = os.path.join(APPS_STAGED, "wefunk")
    if not (os.path.exists(WFPLAY) and os.path.isdir(root)):
        print("warn  wfplay not started: run wfplay/build.sh and tools/build_wefunk.py")
        return None
    state = os.path.join(HERE, ".wfstate")
    shutil.rmtree(state, ignore_errors=True)
    os.makedirs(state)
    proc = subprocess.Popen([WFPLAY, "--root", root, "--port", "8089", "--null",
                             "--state", os.path.join(state, "pos"),
                             "--eq", os.path.join(HERE, ".eqstate", "btaeq.conf")],
                            stderr=subprocess.DEVNULL)
    for call in [None] + list(calls):
        for _ in range(50):
            try:
                if call:
                    urllib.request.urlopen("http://127.0.0.1:8089" + call, timeout=1).read()
                else:
                    urllib.request.urlopen("http://127.0.0.1:8089/status", timeout=1).read()
                break
            except OSError:
                time.sleep(0.05)
        time.sleep(0.3)
    return proc


class Preview(QObject):
    def __init__(self, args):
        super().__init__()
        self.args = args
        self.view = QQuickView()
        self.view.setResizeMode(QQuickView.SizeViewToRootObject)
        self.view.setTitle("PF-3678 preview: " + args.screen)
        self.engine = self.view.engine()
        self.engine.addImportPath(BUILD)
        self.load()

    def scenario(self):
        path = os.path.join(HERE, "scenarios", self.args.scenario + ".json")
        return json.load(open(path)) if os.path.exists(path) else {}

    def load(self):
        self.engine.clearComponentCache()
        build(self.engine, self.scenario())
        comp = QQmlComponent(self.engine, QUrl.fromLocalFile(os.path.join(BUILD, "Mocks.qml")))
        self.mocks = comp.create()
        if not self.mocks:
            sys.exit("mock generation failed: %s" % comp.errors())
        self.mocks.called.connect(self.on_called)
        ctx = self.engine.rootContext()
        mo = self.mocks.metaObject()
        for i in range(mo.propertyOffset(), mo.propertyCount()):
            name = mo.property(i).name()
            ctx.setContextProperty(name, self.mocks.property(name))
        self.view.setSource(QUrl.fromLocalFile(os.path.join(BUILD, self.args.screen)))
        root = self.view.rootObject()
        for assignment in self.args.prop or []:     # --prop name=value on the root item
            name, _, value = assignment.partition("=")
            if root is not None:
                try:
                    parsed = json.loads(value)
                except ValueError:
                    parsed = value          # plain text, e.g. a code like 0000
                root.setProperty(name, parsed if not isinstance(parsed, (int, float)) or value == str(parsed) else value)

    @Slot(str, "QVariant")
    def on_called(self, what, args):
        print("call ", what, json.dumps(args))


NOISE = (
    "Implicitly defined onFoo properties in Connections are deprecated",  # QtQuick 1 syntax, fine on the unit
    "overrides a member of the base object",
    "qt.qpa.fonts", "Populating font family aliases",
)


def register_ui_images():
    """Pack ui/images (our icons) into a bundle so qrc:/bmp_BB_* resolves like on the unit."""
    images = os.path.join(UI_DIR, "images")
    if not os.path.isdir(images):
        return
    sys.path.insert(0, os.path.join(PROJECT, "tools"))
    import rcc_pack
    out = os.path.join(HERE, ".ui_images.rcc")
    rcc_pack.pack(images, out)
    QResource.registerResource(out)


def start_eq_server(initial_query):
    """Serve the real EQ CGI on 127.0.0.1:8088 with state kept under preview/.eqstate."""
    import subprocess
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    state = os.path.join(HERE, ".eqstate")
    shutil.rmtree(state, ignore_errors=True)
    os.makedirs(state)
    share = os.path.join(PROJECT, "rootfs", "usr", "local", "share", "btaeq")
    script = read(os.path.join(share, "www", "cgi-bin", "eq"))
    script = script.replace("/usr/local/share/btaeq/presets", os.path.join(share, "presets"))
    script = script.replace("/var/local", state)
    cgi = os.path.join(state, "eq.sh")
    with open(cgi, "w") as fh:
        fh.write(script)

    def run(query):
        out = subprocess.run(["sh", cgi], env={"QUERY_STRING": query, "PATH": os.environ["PATH"]},
                             capture_output=True, text=True).stdout
        return out.split("\n\n", 1)[-1]

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path, _, query = self.path.partition("?")
            body = run(query).encode() if path == "/cgi-bin/eq" else b"not found"
            self.send_response(200 if path == "/cgi-bin/eq" else 404)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            print("eq   ", self.path)

    if initial_query:
        run(initial_query)
    try:
        server = ThreadingHTTPServer(("127.0.0.1", 8088), Handler)
    except OSError as e:
        print("warn  EQ mock server not started:", e)
        return
    threading.Thread(target=server.serve_forever, daemon=True).start()


def filter_stderr():
    """Tidy Qt's warnings: drop known noise, shorten build paths, skip source excerpts.

    Done on the raw stderr file descriptor rather than with qInstallMessageHandler: QML
    loads on a worker thread, and a Python handler there deadlocks against the main
    thread holding the GIL inside setSource()."""
    read_fd, write_fd = os.pipe()
    real_stderr = os.fdopen(os.dup(2), "w", buffering=1)
    os.dup2(write_fd, 2)
    os.close(write_fd)
    prefix = QUrl.fromLocalFile(BUILD).toString() + "/"

    def pump():
        with os.fdopen(read_fd, errors="replace") as lines:
            for line in lines:
                if any(n in line for n in NOISE) or line.startswith((" ", "\t")) or not line.strip():
                    continue
                real_stderr.write(line.replace(prefix, ""))

    thread = threading.Thread(target=pump, daemon=True)
    thread.start()
    return thread


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("screen", help="qrc-style path, e.g. btaudio/BtAudioTopScreen.qml")
    ap.add_argument("--shot", help="render once to this PNG and exit")
    ap.add_argument("--scenario", default="playing", help="preview/scenarios/NAME.json")
    ap.add_argument("--watch", action="store_true", help="reload when files in ui/ change")
    ap.add_argument("--prop", action="append", help="set a root property, e.g. --prop mode=confirm")
    ap.add_argument("--delay", type=int, default=600, help="ms to wait before --shot")
    args = ap.parse_args()

    if args.shot:
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    QQuickWindow.setGraphicsApi(QSGRendererInterface.Software)
    stderr_thread = filter_stderr()
    app = QGuiApplication(sys.argv)
    QResource.registerResource(IMAGES_RCC)
    register_ui_images()
    scenario_path = os.path.join(HERE, "scenarios", args.scenario + ".json")
    eq_query = json.load(open(scenario_path)).get("eq", "preset=boombox") if os.path.exists(scenario_path) else ""
    start_eq_server(eq_query)
    scenario = json.load(open(scenario_path)) if os.path.exists(scenario_path) else {}
    wfplay = start_wfplay(scenario.get("wefunk", [])) if args.screen.startswith("APPS/") else None
    translator = QTranslator()
    translator.load(STRINGS_QM)
    app.installTranslator(translator)

    preview = Preview(args)
    preview.view.show()

    if args.shot:
        def shoot():
            preview.view.grabWindow().save(args.shot)
            print("saved", args.shot)
            app.quit()
        QTimer.singleShot(args.delay, shoot)  # let Loaders, Timers and animations settle
    elif args.watch:
        watcher = QFileSystemWatcher()
        def rewatch():
            for d in (UI_DIR, APPS_DIR):
                for dirpath, _, files in os.walk(d):
                    watcher.addPath(dirpath)
                    watcher.addPaths([os.path.join(dirpath, f) for f in files])
        def changed(_):
            print("---- reload")
            preview.load()
            rewatch()
        if os.path.isdir(UI_DIR):
            rewatch()
        watcher.directoryChanged.connect(changed)
        watcher.fileChanged.connect(changed)
    status = app.exec()
    if wfplay:
        wfplay.terminate()
    sys.stdout.flush()
    os.close(2)  # end of stream for the filter thread
    stderr_thread.join(timeout=1)
    sys.exit(status)


if __name__ == "__main__":
    main()
