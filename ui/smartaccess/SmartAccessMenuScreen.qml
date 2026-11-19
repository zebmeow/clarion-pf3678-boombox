/* Boombox APPS: loads the launcher from the card's FAT partition, so apps live
 * there (APPS/ on /media/map) and update without touching this bundle. */
import QtQuick 1.1
import ClarionQt 1.0

Item {
    id: smartaccessMenuScreen
    width: 800
    height: 480

    Rectangle { anchors.fill: parent; color: "#07080b" }
    MouseArea { anchors.fill: parent }

    Loader {
        id: l
        anchors.fill: parent
        source: "file:///media/map/APPS/Apps.qml"
    }

    Column {
        anchors.centerIn: parent
        spacing: 24
        visible: l.status === Loader.Error
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Apps not found on the card"
            color: "#f4f6fa"
            font.pixelSize: 26
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 280
            height: 72
            radius: 36
            color: "#ffb547"
            Text {
                anchors.centerIn: parent
                text: "Back to music"
                color: "#1b1206"
                font.pixelSize: 25
                font.bold: true
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (SourceControl.SOURCE_BT_AUDIO !== mySourceControl.sourceType)
                        mySourceControl.requestChangeSource(SourceControl.SOURCE_BT_AUDIO)
                    else
                        myAudioMgr.requestOpenAudioScreen(SourceControl.SOURCE_BT_AUDIO)
                }
            }
        }
    }
}
