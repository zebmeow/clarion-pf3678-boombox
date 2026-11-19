#!/usr/bin/env python3
"""Flag QML/JS that Qt 4.8 (QtQuick 1.1, JavaScriptCore ES5) cannot run.

    qt4check.py [DIR...]        (default: ../ui)

The desktop preview runs on Qt 6 and happily accepts Qt Quick 2 features, so check
before repacking for the unit. Exit status is non-zero when anything is found.
"""
import os
import re
import sys

QTQUICK1_TYPES = set("""
Item Rectangle Image BorderImage AnimatedImage Text TextInput TextEdit MouseArea FocusScope
Flickable Flipable PinchArea Column Row Grid Flow Repeater ListView GridView PathView Path
PathLine PathQuad PathCubic PathAttribute PathPercent ListModel ListElement VisualItemModel
VisualDataModel XmlListModel XmlRole Package Loader Component Connections Timer QtObject
Binding State StateGroup PropertyChanges StateChangeScript ParentChange AnchorChanges
Transition Behavior SequentialAnimation ParallelAnimation PropertyAnimation NumberAnimation
ColorAnimation RotationAnimation Vector3dAnimation ParentAnimation AnchorAnimation
PauseAnimation SmoothedAnimation SpringAnimation PropertyAction ScriptAction Gradient
GradientStop SystemPalette FontLoader IntValidator DoubleValidator RegExpValidator Rotation
Scale Translate WorkerScript Keys KeyNavigation
""".split())

# C++ types the unit's ClarionQt plugin provides
CLARION_TYPES = {"BasicLabel", "BasicListLabel", "CBufferImage", "ArtworkImage",
                 "CPandoraArtwork", "CSXMChannelLogo", "CAhaImage", "CameraGuideLine"}

RULES = [
    (r"^\s*import\s+(?!QtQuick\s+1\.[01]\s*$|ClarionQt\s+1\.0\s*$|\")", "import not available on the unit"),
    (r"\bproperty\s+var\b", "'property var' is Qt 5; use 'property variant'"),
    (r"\breadonly\s+property\b", "'readonly property' is Qt 5"),
    (r"\bproperty\s+\w+\s+on[A-Z]\w*", "property names like onFoo are parsed as signal handlers"),
    (r"\brequired\s+property\b", "'required property' is Qt 5.15+"),
    (r"^\s*component\s+\w+\s*:", "inline components are Qt 5.15+"),
    (r"^\s*pragma\b", "pragmas are Qt 5+"),
    (r"^\s*enum\s+\w+\s*\{", "QML enums are Qt 5.10+"),
    (r"\b(let|const)\s+\w", "let/const are ES6; use var"),
    (r"=>", "arrow functions are ES6"),
    (r"`", "template literals are ES6"),
    (r"\?\.|\?\?", "optional chaining / nullish coalescing are ES2020"),
    (r"\.\.\.\w", "spread/rest is ES6"),
    (r"\bclass\s+\w+", "classes are ES6"),
    (r"\.(includes|startsWith|endsWith|padStart|padEnd|find|findIndex)\s*\(", "ES6+ string/array method"),
    (r"\bQt\.(binding|callLater|resolvedUrl\b|platform\.os)", "Qt 5 global object API"),
    (r"\b(antialiasing|mipmap|fontSizeMode|minimumPixelSize|cursorShape|layer\.\w+|asynchronous)\s*:",
     "property not in QtQuick 1.1"),
    (r"\bonWheel\s*:", "MouseArea.onWheel is Qt 5"),
    (r"\bproperty\s+\w+\s+(pos|parent|x|y|z|opacity|enabled|visible|rotation|scale|width|height|"
     r"transformOriginPoint|effect|children|state|states|transitions|smooth|clip|focus|anchors|data|"
     r"resources|transform|objectName)\b",
     "Qt 4 items already have this (QGraphicsObject/QDeclarativeItem): 'cannot override FINAL property'"),
    (r"^\s*active\s*:", "Loader.active is Qt 5 (fine on other types; check)"),
]


def strip_comments(text):
    """Blank out comments and string contents in one pass (keeping line numbers), so
    neither can trip the rules. Template literals are kept so the ES6 rule sees them."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("\n" * text.count("\n", i, j))
            i = j
        elif c in "\"'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(c + c)
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def check(root):
    local_types = set()
    files = []
    for dirpath, _, names in os.walk(root):
        for n in names:
            if n.endswith((".qml", ".js")):
                files.append(os.path.join(dirpath, n))
                if n.endswith(".qml"):
                    local_types.add(n[:-4])
    # types defined by the stock QML tree are available too once repacked
    stock = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "stock", "qml")
    for dirpath, _, names in os.walk(stock):
        local_types.update(n[:-4] for n in names if n.endswith(".qml"))

    findings = []
    for path in sorted(files):
        text = strip_comments(open(path, encoding="utf-8", errors="replace").read())
        lines = text.split("\n")
        for i, line in enumerate(lines, 1):
            for pattern, why in RULES:
                if path.endswith(".js") and why.startswith(("import", "'property", "inline", "QML")):
                    continue
                if re.search(pattern, line):
                    findings.append((path, i, why, line.strip()))
            if path.endswith(".qml"):
                for t in re.findall(r"^\s*([A-Z][A-Za-z0-9_]*)\s*\{", line):
                    if t not in QTQUICK1_TYPES | CLARION_TYPES | local_types:
                        findings.append((path, i, "type '%s' does not exist in QtQuick 1.1" % t, line.strip()))
        # function-style handlers only mean something inside Connections
        for m in re.finditer(r"\bConnections\s*\{", text):
            depth, j = 1, m.end()
            while j < len(text) and depth:
                depth += {"{": 1, "}": -1}.get(text[j], 0)
                j += 1
            for h in re.finditer(r"\bfunction\s+on[A-Z]\w*\s*\(", text[m.end():j]):
                at = m.end() + h.start()
                findings.append((path, text.count("\n", 0, at) + 1,
                                 "function-style Connections handlers are Qt 5.15+; use 'onFoo:'",
                                 lines[text.count("\n", 0, at)].strip()))
    return findings


def main():
    roots = sys.argv[1:] or [os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ui")]
    findings = []
    for root in roots:
        findings += check(root)
    for path, line, why, src in findings:
        print("%s:%d: %s\n    %s" % (os.path.relpath(path), line, why, src[:100]))
    print("%d issue%s" % (len(findings), "" if len(findings) == 1 else "s"))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
