/* Boombox APPS launcher, loaded from the card (/media/map/APPS/Apps.qml) by the APPS
 * screen in the system bundle (smartaccess/SmartAccessMenuScreen.qml), so apps can be
 * added or updated by copying files to the card's FAT partition.
 * Each app is a folder with a Main.qml that emits closed(). If the WEFUNK player is
 * playing, APPS goes straight back into it. */
import QtQuick 1.1
import ClarionQt 1.0

Item {
    id: apps
    width: 800
    height: 480

    property string font: myTextStyle.getFontName(TextStyle.FP_AUDIO_TOPINFO_TITLE, 0)
    property string current: ""          /* folder of the open app, "" = launcher */
    property string loadError: ""

    /* qtapp's output goes to /dev/null on the unit, so a screen that fails to load says
       why on screen and in BOOMBOX/QMLLOG.TXT on the card (written by wfplay) */
    function reportError() {
        var c = Qt.createComponent(current + "/Main.qml")
        loadError = c.errorString()
        var x = new XMLHttpRequest()
        x.open("GET", "http://127.0.0.1:8089/log?m=" + encodeURIComponent(current + ": " + loadError))
        x.send()
    }

    function beep() {
        mySoundUtility.requestSoundBeep(CSoundUtility.BEEPKIND_NORMAL)
    }

    function backToMusic() {
        beep()
        if (SourceControl.SOURCE_BT_AUDIO !== mySourceControl.sourceType)
            mySourceControl.requestChangeSource(SourceControl.SOURCE_BT_AUDIO)
        else
            myAudioMgr.requestOpenAudioScreen(SourceControl.SOURCE_BT_AUDIO)
    }

    Component.onCompleted: {
        var x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState === 4 && x.status === 200 && x.responseText.indexOf("\"state\":\"playing\"") >= 0)
                apps.current = "wefunk"
        }
        x.open("GET", "http://127.0.0.1:8089/status")
        x.send()
    }

    MouseArea { anchors.fill: parent }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#151a24" }
            GradientStop { position: 1.0; color: "#07080b" }
        }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 34
        text: "Apps"
        color: "#f4f6fa"
        font.family: apps.font
        font.pixelSize: 34
        font.bold: true
    }

    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 100
        spacing: 28

        /* WEFUNK: the tile is a little web-player window */
        Item {
            width: 200
            height: 236
            Rectangle {
                width: 200
                height: 200
                radius: 24
                color: wefunkTouch.pressed ? "#222a37" : "#141922"
                border.color: "#283040"
                border.width: 1
                smooth: true
                Rectangle {
                    anchors.centerIn: parent
                    width: 150
                    height: 124
                    color: "#4a3a9e"
                    Rectangle {
                        width: parent.width
                        height: 26
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "#bdc6e1" }
                            GradientStop { position: 1.0; color: "#5d647c" }
                        }
                    }
                    Rectangle {
                        x: 12; y: 38; width: 126; height: 74
                        color: "#2424b4"
                        border.color: "#5c5cf2"
                        border.width: 3
                        Text {
                            anchors.centerIn: parent
                            text: "WEFUNK"
                            color: "#d8cc2c"
                            font.family: apps.font
                            font.bold: true
                            font.pixelSize: 24
                            style: Text.Raised
                            styleColor: "#0a0a4e"
                        }
                    }
                }
                MouseArea {
                    id: wefunkTouch
                    anchors.fill: parent
                    onClicked: { apps.beep(); apps.current = "wefunk" }
                }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 208
                text: "WEFUNK Radio"
                color: "#f4f6fa"
                font.family: apps.font
                font.pixelSize: 22
                font.bold: true
            }
        }

        Repeater {
            model: ["Visualizer", "Game"]
            Item {
                width: 200
                height: 236
                Rectangle {
                    width: 200
                    height: 200
                    radius: 24
                    color: "#0f131a"
                    border.color: "#1d2330"
                    border.width: 1
                    smooth: true
                    Text {
                        anchors.centerIn: parent
                        text: "Soon"
                        color: "#687183"
                        font.family: apps.font
                        font.pixelSize: 24
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 208
                    text: modelData
                    color: "#687183"
                    font.family: apps.font
                    font.pixelSize: 22
                }
            }
        }
    }

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 360
        width: 300
        height: 68
        radius: 34
        color: backTouch.pressed ? "#c9741c" : "#ffb547"
        smooth: true
        Text {
            anchors.centerIn: parent
            text: "Back to music"
            color: "#1b1206"
            font.family: apps.font
            font.pixelSize: 25
            font.bold: true
        }
        MouseArea {
            id: backTouch
            anchors.fill: parent
            anchors.margins: -6
            onClicked: apps.backToMusic()
        }
    }

    Loader {
        id: app
        anchors.fill: parent
        source: apps.current === "" ? "" : apps.current + "/Main.qml"
        onStatusChanged: if (status === Loader.Error) apps.reportError()
    }
    Connections {
        target: app.item
        ignoreUnknownSignals: true
        onClosed: apps.current = ""
    }
    Rectangle {                 /* an app that fails to load: say why instead of a blank screen */
        anchors.fill: parent
        visible: app.status === Loader.Error
        color: "#07080b"
        MouseArea { anchors.fill: parent }
        Text {
            x: 48; y: 40; width: parent.width - 96
            text: "Could not open " + apps.current
            color: "#ffb547"
            font.family: apps.font
            font.pixelSize: 26
            font.bold: true
        }
        Text {
            x: 48; y: 90; width: parent.width - 96; height: 250
            text: apps.loadError
            color: "#f4f6fa"
            font.family: apps.font
            font.pixelSize: 18
            wrapMode: Text.WrapAnywhere
            clip: true
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 360; width: 220; height: 68; radius: 34
            color: "#ffb547"
            Text {
                anchors.centerIn: parent
                text: "Back"
                color: "#1b1206"
                font.family: apps.font
                font.pixelSize: 25
                font.bold: true
            }
            MouseArea {
                anchors.fill: parent
                anchors.margins: -6
                onClicked: { apps.beep(); apps.current = "" }
            }
        }
    }
}
