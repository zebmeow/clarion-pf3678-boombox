/* Boombox volume pop-up (replaces the stock one; qtapp shows it over the current
 * screen while the volume knob turns). Same data as stock: mySoundUtility.volumeValue
 * (0-40), volumeText, mute. Tapping it closes it, as before. */
import QtQuick 1.1
import ClarionQt 1.0

Item {
    id: volume
    x: 0
    width: ScreenMgr.RUNTIME_SCREEN_WIDTH
    height: 62

    MouseArea {
        anchors.fill: parent
        onClicked: myScreenMgr.deleteImpose(CScreenData.RUNTIME_SID_IMPOSE_VOLUME, false)
    }

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: 24
        anchors.rightMargin: 24
        radius: 31
        color: "#ee141922"
        border.color: "#283040"
        border.width: 1
        smooth: true

        Text {
            x: 26
            anchors.verticalCenter: parent.verticalCenter
            text: mySoundUtility.mute ? "Muted" : "Volume"
            color: mySoundUtility.mute ? "#ffb547" : "#a9b1bf"
            font.family: myTextStyle.getFontName(TextStyle.FP_AUDIO_TOPINFO_TITLE, 0)
            font.pixelSize: 22
        }
        Rectangle {          // track
            id: track
            x: 140
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 140 - 96
            height: 10
            radius: 5
            color: "#283040"
            Rectangle {      // level
                width: Math.max(height, parent.width * Math.min(40, mySoundUtility.volumeValue) / 40)
                height: parent.height
                radius: 5
                color: mySoundUtility.mute ? "#687183" : "#ffb547"
                Behavior on width { NumberAnimation { duration: 80 } }
            }
        }
        Text {
            anchors.right: parent.right
            anchors.rightMargin: 26
            anchors.verticalCenter: parent.verticalCenter
            text: mySoundUtility.volumeText
            color: "#f4f6fa"
            font.family: myTextStyle.getFontName(TextStyle.FP_AUDIO_TOPINFO_TITLE, 0)
            font.pixelSize: 28
            font.bold: true
        }
    }
}
