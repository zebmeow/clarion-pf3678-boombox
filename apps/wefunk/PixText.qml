/* Silkscreen text drawn from pre-rendered sprite sheets (font/*.png, tools/make_pixfont.py),
 * because the unit's font engine draws nothing for TrueType fonts. Each glyph is a
 * clipped slice of the sheet; the 2 px drop shadow is baked in.
 * Colours must be among make_pixfont.py's COLORS/SHADOWS, sizes 16 or 24.
 * Width: set `box` to constrain (elide / wrap / align); otherwise it is the text's own. */
import QtQuick 1.1
import "font.js" as F

Item {
    id: p
    property string text: ""
    property int size: 16
    property string color: "#dcdcec"
    property string shadow: "#0a0a4e"
    property int box: 0
    property bool elide: false
    property bool wrap: false
    property int maxLines: 2
    property string align: "left"

    property variant lay: F.layout(text, size, box, elide, wrap, maxLines, align)
    property real paintedWidth: lay.w
    property string sheet: "font/" + size + "-" + color.substring(1).toLowerCase() + "-" +
                           shadow.substring(1).toLowerCase() + ".png"

    width: box > 0 ? box : lay.w
    height: lay.h

    Repeater {
        model: p.lay.g
        Item {
            x: modelData[3]
            y: modelData[4]
            width: modelData[2]
            height: p.lay.ch
            clip: true
            Image {
                x: -modelData[0]
                y: -modelData[1]
                source: p.sheet
                smooth: false
            }
        }
    }
}
