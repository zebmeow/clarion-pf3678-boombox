/* The web player's bevelled grey button (.zb), sized for the resistive touch panel.
 * The touch area reaches a few px past the face so slightly-off taps still land. */
import QtQuick 1.1
import ClarionQt 1.0

Item {
    id: b
    property string label: ""
    property string glyph: ""
    property real glyphPx: 4
    property int textSize: 16
    property bool latched: false     /* current tab: sunken, yellow text */
    property int edge: 3
    property bool down: touch.pressed
    signal clicked

    width: 120
    height: 56
    opacity: enabled ? 1.0 : 0.45

    Rectangle {
        anchors.fill: parent
        color: b.down || b.latched ? "#727a93" : "#828aa4"
    }
    /* bevel: light top/left, dark bottom/right; swapped while pressed */
    Rectangle { width: parent.width; height: b.edge; color: b.down || b.latched ? "#3b4258" : "#c4cde8" }
    Rectangle { width: b.edge; height: parent.height; color: b.down || b.latched ? "#3b4258" : "#c4cde8" }
    Rectangle { y: parent.height - b.edge; width: parent.width; height: b.edge; color: b.down || b.latched ? "#c4cde8" : "#3b4258" }
    Rectangle { x: parent.width - b.edge; width: b.edge; height: parent.height; color: b.down || b.latched ? "#c4cde8" : "#3b4258" }

    Row {
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: b.down ? 2 : 0
        anchors.verticalCenterOffset: b.down ? 2 : 0
        spacing: 10
        Glyph {
            visible: b.glyph !== ""
            kind: b.glyph
            px: b.glyphPx
            anchors.verticalCenter: parent.verticalCenter
            color: b.latched ? "#d8cc2c" : "#faffff"
        }
        PixText {
            visible: b.label !== ""
            text: b.label
            size: b.textSize
            anchors.verticalCenter: parent.verticalCenter
            color: b.latched ? "#d8cc2c" : "#e4e9f7"
            shadow: "#34343e"
        }
    }

    MouseArea {
        id: touch
        anchors.fill: parent
        anchors.margins: -6
        onClicked: {
            mySoundUtility.requestSoundBeep(CSoundUtility.BEEPKIND_NORMAL)
            b.clicked()
        }
    }
}
