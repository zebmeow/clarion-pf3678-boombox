/*******************************************************************************
    File Name   : SourceSelectScreen.qml
    Summary     : Boombox: Bluetooth is the only source, so the source list goes straight to it. The screen shows
                  the boombox background, switches the source to Bluetooth (which
                  opens the now-playing screen) and, if that fails, shows a hint.
*******************************************************************************/
import QtQuick 1.1
import ClarionQt 1.0

Item {
    id: sourceSelectScreen
    width: ScreenMgr.RUNTIME_SCREEN_WIDTH
    height: ScreenMgr.RUNTIME_SCREEN_HEIGHT
    property int nCurModeIndex: -1     // stock interface, kept in case other screens use it
    signal sourceButtonSelect()

    function openAudioScreen(nIndex) {
        openBoombox()
    }

    /* Audio may be off (or another source active): then only switching the source to
     * Bluetooth opens its screen; opening the screen alone does nothing. */
    function openBoombox() {
        if (SourceControl.SOURCE_BT_AUDIO !== mySourceControl.sourceType)
            mySourceControl.requestChangeSource(SourceControl.SOURCE_BT_AUDIO)
        else
            myAudioMgr.requestOpenAudioScreen(SourceControl.SOURCE_BT_AUDIO)
    }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#151a24" }
            GradientStop { position: 1.0; color: "#07080b" }
        }
    }

    Text {
        id: hint
        anchors.centerIn: parent
        visible: false
        text: "Tap to open Bluetooth audio"
        color: "#a9b1bf"
        font.pixelSize: 24
    }

    /* tapping retries (the hint appears if the automatic attempts did not switch) */
    MouseArea {
        anchors.fill: parent
        onClicked: openBoombox()
    }

    /* first attempt right after loading; a few retries; then show the hint */
    Timer {
        property int tries: 0
        interval: 800
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            if (tries === 0)
                openBoombox()
            else if (tries < 4)
                myAudioMgr.requestOpenAudioScreen(SourceControl.SOURCE_BT_AUDIO)
            else {
                stop()
                hint.visible = true
            }
            tries++
        }
    }
}
