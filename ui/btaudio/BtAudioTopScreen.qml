/*******************************************************************************
    File Name   : BtAudioTopScreen.qml
    Summary     : Boombox now-playing screen (replaces the stock BT audio top screen)
*******************************************************************************/
import QtQuick 1.1
import ClarionQt 1.0

Item {
    id: btAudioBaseScreen
    width: ScreenMgr.RUNTIME_SCREEN_WIDTH
    height: ScreenMgr.RUNTIME_SCREEN_HEIGHT

    property bool connecting: CBTAudioControl.BTA_STATE_CONNECTING === myCBTAudioControl.btState
    property bool connected: !connecting &&
                             CBTAudioControl.BTA_STATE_UNREGISTER !== myCBTAudioControl.btState &&
                             CBTAudioControl.BTA_STATE_REGISTER_CONNCET_UNSELECT !== myCBTAudioControl.btState &&
                             CBTAudioControl.STREAM_STATE_DISCONNECT !== myCBTAudioControl.streamState &&
                             CBTAudioControl.STREAM_STATE_DISCONNECT_OFF !== myCBTAudioControl.streamState
    property bool playing: connected && CBTAudioControl.STREAM_STATE_ON === myCBTAudioControl.streamState
    property bool hasMeta: CBTAudioControl.AVRCP_VERSION_13 === myCBTAudioControl.btVersion ||
                           CBTAudioControl.AVRCP_VERSION_14 === myCBTAudioControl.btVersion
    property string eqPreset: ""

    /* colours and font (inline: no new files can be added to the bundle) */
    QtObject {
        id: theme
        property string font: myTextStyle.getFontName(TextStyle.FP_AUDIO_TOPINFO_TITLE, 0)
        property color bgTop: "#151a24"
        property color bgBottom: "#07080b"
        property color panel: "#141922"
        property color line: "#283040"
        property color text: "#f4f6fa"
        property color textDim: "#a9b1bf"
        property color textFaint: "#687183"
        property color accent: "#ffb547"
        property color accentDeep: "#c9741c"
        property string eqUrl: "http://127.0.0.1:8088/cgi-bin/eq"
    }

    function beep() {
        mySoundUtility.requestSoundBeep(CSoundUtility.BEEPKIND_NORMAL)
    }

    function refreshEqPreset() {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200) {
                var m = /preset=(\w+)/.exec(xhr.responseText)
                if (m)
                    eqPreset = m[1].charAt(0).toUpperCase() + m[1].slice(1)
            }
        }
        xhr.open("GET", theme.eqUrl + "?get")
        xhr.send()
    }

    Component.onCompleted: refreshEqPreset()

    /* background */
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: theme.bgTop }
            GradientStop { position: 1.0; color: theme.bgBottom }
        }
    }

    /* speaker cone: the boombox's "artwork"; the dust cap pulses while playing */
    Item {
        id: cone
        x: 40
        y: 100
        width: 260
        height: 260
        opacity: btAudioBaseScreen.connected ? 1.0 : 0.45
        Behavior on opacity { NumberAnimation { duration: 300 } }

        Rectangle {          // frame
            anchors.fill: parent
            radius: width / 2
            color: "#10141b"
            border.color: theme.line
            border.width: 2
            smooth: true
        }
        Repeater {           // mounting screws
            model: 4
            Rectangle {
                width: 10
                height: 10
                radius: 5
                color: theme.line
                smooth: true
                x: cone.width / 2 + 116 * Math.cos(Math.PI / 4 + index * Math.PI / 2) - 5
                y: cone.height / 2 + 116 * Math.sin(Math.PI / 4 + index * Math.PI / 2) - 5
            }
        }
        Rectangle {          // surround
            anchors.centerIn: parent
            width: 204
            height: width
            radius: width / 2
            color: "#0b0e13"
            border.color: "#1f2632"
            border.width: 8
            smooth: true
        }
        Rectangle {          // cone body
            anchors.centerIn: parent
            width: 168
            height: width
            radius: width / 2
            smooth: true
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#232a36" }
                GradientStop { position: 1.0; color: "#0d1016" }
            }
        }
        Rectangle {          // dust cap
            id: dustCap
            anchors.centerIn: parent
            width: 76
            height: width
            radius: width / 2
            smooth: true
            gradient: Gradient {
                GradientStop { position: 0.0; color: btAudioBaseScreen.connected ? theme.accent : "#3a4252" }
                GradientStop { position: 1.0; color: btAudioBaseScreen.connected ? theme.accentDeep : "#222833" }
            }
            SequentialAnimation on scale {
                running: btAudioBaseScreen.playing
                loops: Animation.Infinite
                NumberAnimation { to: 1.08; duration: 180; easing.type: Easing.OutQuad }
                NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
            }
        }
    }

    /* Overlays (EQ, Bluetooth) live in existing stock slots of unreachable screens:
     *   aha/AhaRadioTopScreen.qml  EQ        sxm/SXMTopScreen.qml  Bluetooth */
    property bool pairOnOpen: false
    function openOverlay(source, pair) {
        beep()
        pairOnOpen = pair
        overlayLoader.source = source
    }

    /* top bar: two large pills, inset from the edges (the resistive panel is
     * unreliable near them) */
    Rectangle {
        id: btChip
        x: 40
        y: 22
        height: 60
        width: btRow.width + 44
        radius: 30
        color: btTouch.pressed ? "#222a37" : theme.panel
        border.color: theme.line
        border.width: 1
        smooth: true
        Row {
            id: btRow
            anchors.centerIn: parent
            spacing: 12
            Image {
                anchors.verticalCenter: parent.verticalCenter
                source: "qrc:/bmp_BB_BT"
                opacity: btAudioBaseScreen.connected ? 1.0 : 0.5
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: btAudioBaseScreen.connected ? "Connected" : (btAudioBaseScreen.connecting ? "Connecting..." : "Bluetooth")
                color: theme.text
                font.family: theme.font
                font.pixelSize: 21
            }
        }
        MouseArea {
            id: btTouch
            anchors.fill: parent
            anchors.margins: -8
            onClicked: btAudioBaseScreen.openOverlay("qrc:/sxm/SXMTopScreen.qml", false)
        }
    }

    Rectangle {
        id: eqChip
        x: 800 - 40 - width
        y: 22
        height: 60
        width: eqRow.width + 44
        radius: 30
        color: eqTouch.pressed ? "#222a37" : theme.panel
        border.color: theme.line
        border.width: 1
        smooth: true
        Row {
            id: eqRow
            anchors.centerIn: parent
            spacing: 12
            Image { source: "qrc:/bmp_BB_EQ"; anchors.verticalCenter: parent.verticalCenter }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: btAudioBaseScreen.eqPreset === "" ? "EQ" : btAudioBaseScreen.eqPreset
                color: theme.text
                font.family: theme.font
                font.pixelSize: 21
            }
        }
        MouseArea {
            id: eqTouch
            anchors.fill: parent
            anchors.margins: -8
            onClicked: btAudioBaseScreen.openOverlay("qrc:/aha/AhaRadioTopScreen.qml", false)
        }
    }

    /* track info */
    Column {
        id: trackInfo
        x: 340
        y: 116
        width: 430
        spacing: 8
        visible: btAudioBaseScreen.connected

        Text {
            width: parent.width
            text: btAudioBaseScreen.hasMeta && myCBTAudioControl.trackTitle !== "" ? myCBTAudioControl.trackTitle : "Bluetooth audio"
            color: theme.text
            font.family: theme.font
            font.pixelSize: 40
            font.bold: true
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            text: btAudioBaseScreen.hasMeta ? myCBTAudioControl.artistTitle : ""
            color: theme.textDim
            font.family: theme.font
            font.pixelSize: 26
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            text: btAudioBaseScreen.hasMeta ? myCBTAudioControl.albumTitle : ""
            color: theme.textFaint
            font.family: theme.font
            font.pixelSize: 20
            elide: Text.ElideRight
        }
        Item { width: 1; height: 6 }
        Row {
            spacing: 14
            Text {
                text: myCBTAudioControl.strPlayTime
                color: theme.accent
                font.family: theme.font
                font.pixelSize: 22
            }
            Text {
                text: btAudioBaseScreen.playing ? "Playing" : "Paused"
                color: theme.textFaint
                font.family: theme.font
                font.pixelSize: 22
            }
        }
    }

    /* not connected / connecting */
    Column {
        x: 340
        y: 150
        width: 420
        spacing: 14
        visible: !btAudioBaseScreen.connected

        Text {
            width: parent.width
            text: btAudioBaseScreen.connecting ? "Connecting..." : "No phone connected"
            color: theme.text
            font.family: theme.font
            font.pixelSize: 34
            font.bold: true
        }
        Text {
            width: parent.width
            text: "A phone paired before connects on its own. For a new phone, start pairing:"
            color: theme.textDim
            font.family: theme.font
            font.pixelSize: 22
            wrapMode: Text.WordWrap
            lineHeight: 1.15
        }
        Item { width: 1; height: 8 }
        Rectangle {
            width: 260
            height: 68
            radius: 34
            color: pairTouch.pressed ? theme.accentDeep : theme.accent
            smooth: true
            visible: !btAudioBaseScreen.connecting
            Text {
                anchors.centerIn: parent
                text: "Pair a phone"
                color: "#1b1206"
                font.family: theme.font
                font.pixelSize: 24
                font.bold: true
            }
            MouseArea {
                id: pairTouch
                anchors.fill: parent
                onClicked: btAudioBaseScreen.openOverlay("qrc:/sxm/SXMTopScreen.qml", true)
            }
        }
    }

    /* transport: previous / play-pause / next. Inline (no separate button file) because
     * the resource bundle is patched in place and cannot gain new files. Holding
     * previous/next rewinds/fast-forwards. */
    function transportTap(index) {
        beep()
        if (index === 0) myCBTAudioControl.requestPrevTrack()
        else if (index === 1) myCBTAudioControl.requestPlayPause()
        else myCBTAudioControl.requestNextTrack()
    }
    function transportHold(index, down) {
        if (index === 0) { if (down) myCBTAudioControl.requestStartFB(); else myCBTAudioControl.requestStopFB() }
        if (index === 2) { if (down) myCBTAudioControl.requestStartFF(); else myCBTAudioControl.requestStopFF() }
    }

    Row {
        anchors.horizontalCenter: trackInfo.horizontalCenter
        y: 334
        height: 112
        spacing: 40
        visible: btAudioBaseScreen.connected

        Repeater {
            model: 3
            Item {
                property bool big: index === 1
                width: big ? 104 : 72
                height: width
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: parent.big ? theme.accent : "transparent"
                    border.color: theme.line
                    border.width: parent.big ? 0 : 2
                    smooth: true
                    scale: touch.pressed ? 0.92 : 1.0
                    Behavior on scale { NumberAnimation { duration: 80 } }

                    Image {
                        anchors.centerIn: parent
                        source: index === 0 ? "qrc:/bmp_BB_PREV" :
                                index === 2 ? "qrc:/bmp_BB_NEXT" :
                                btAudioBaseScreen.playing ? "qrc:/bmp_BB_PAUSE_DARK" : "qrc:/bmp_BB_PLAY_DARK"
                    }
                }
                MouseArea {
                    id: touch
                    property bool held: false
                    anchors.fill: parent
                    anchors.margins: -10          // generous touch target
                    onPressed: held = false
                    onPressAndHold: {
                        if (index !== 1) {
                            held = true
                            btAudioBaseScreen.transportHold(index, true)
                        }
                    }
                    onReleased: if (held) btAudioBaseScreen.transportHold(index, false)
                    onClicked: if (!held) btAudioBaseScreen.transportTap(index)
                }
            }
        }
    }

    /* overlay screens (EQ, Bluetooth) */
    Loader {
        id: overlayLoader
        anchors.fill: parent
        onLoaded: {
            item.overlay = true
            if (btAudioBaseScreen.pairOnOpen)
                item.startPairing()
        }
    }
    Connections {
        target: overlayLoader.item
        ignoreUnknownSignals: true
        onClosed: {
            overlayLoader.source = ""
            btAudioBaseScreen.refreshEqPreset()
        }
    }
}
