/* Boombox standby (audio off) screen: Play switches the unit to Bluetooth audio.
 * Stock easter egg kept: tap the corners top-left, top-right, bottom-left,
 * bottom-right to open the factory "Line Diag" test menu. */
import QtQuick 1.1
import ClarionQt 1.0

Item {
    id: audioOffScreen
    width: ScreenMgr.RUNTIME_SCREEN_WIDTH
    height: ScreenMgr.RUNTIME_SCREEN_HEIGHT
    property int nNum: -1
    property string font: myTextStyle.getFontName(TextStyle.FP_AUDIO_TOPINFO_TITLE, 0)

    function corner(i) {
        nNum = (i === nNum + 1) ? i : (i === 0 ? 0 : -1)
        if (nNum === 3) {
            nNum = -1
            testLoader.source = "qrc:/testmode/TestModeTopScreen.qml"
            myDisplayUtility.requestGetAuxPortValue()
            myDisplayUtility.requestGetMICPortValue()
            mySystemConfig.requestGetUartStatus()
        }
    }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#151a24" }
            GradientStop { position: 1.0; color: "#07080b" }
        }
    }
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 92
        text: "Audio off"
        color: "#f4f6fa"
        font.family: audioOffScreen.font
        font.pixelSize: 34
        font.bold: true
    }
    Rectangle {
        id: play
        anchors.centerIn: parent
        width: 120
        height: 120
        radius: 60
        color: "#ffb547"
        smooth: true
        scale: playTouch.pressed ? 0.92 : 1.0
        Image { anchors.centerIn: parent; source: "qrc:/bmp_BB_PLAY_DARK" }
        MouseArea {
            id: playTouch
            anchors.fill: parent
            anchors.margins: -20
            onClicked: {
                mySoundUtility.requestSoundBeep(CSoundUtility.BEEPKIND_NORMAL)
                mySourceControl.requestChangeSource(SourceControl.SOURCE_BT_AUDIO)
            }
        }
    }
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: play.bottom
        anchors.topMargin: 28
        text: "Tap to play Bluetooth audio"
        color: "#a9b1bf"
        font.family: audioOffScreen.font
        font.pixelSize: 22
    }

    Repeater {           // invisible corner buttons: 0 TL, 1 TR, 2 BL, 3 BR
        model: 4
        MouseArea {
            x: index % 2 ? 624 : 0
            y: index > 1 ? 285 : 0
            width: 176
            height: 195
            onClicked: audioOffScreen.corner(index)
        }
    }

    Loader {
        id: testLoader
        Connections {
            target: mySystemMgr
            onNotifyCloseTestMode: testLoader.source = ""
        }
    }
}
