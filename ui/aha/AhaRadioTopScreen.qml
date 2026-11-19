/*******************************************************************************
    File Name   : AhaRadioTopScreen.qml
    Summary     : Boombox EQUALIZER screen for the software EQ (libbtaeq.so, via
                  /cgi-bin/eq). The bundle is patched in place, so this file lives in
                  two existing slots:
                    aha/AhaRadioTopScreen.qml                overlay from the EQ chip
                    settings/SettingsSoundGraphicScreen.qml  tune-knob hold (copied at
                                                             build time; keeps that
                                                             screen's stock interface)
                  Touch layout: nothing tappable within ~40 px of the screen edges
                  (the resistive panel is unreliable there), large targets.
*******************************************************************************/
import QtQuick 1.1
import ClarionQt 1.0

Item {
    id: eq
    width: 800
    height: 480

    /* overlay = opened from the now-playing screen (set by its Loader) */
    property bool overlay: false
    signal closed

    /* stock interface of settings/SettingsSoundGraphicScreen.qml */
    property real nSidLoader: 0
    signal backToSoundMainScreen()
    function getEqGain(nIndex) { return 0 }

    property variant gains: [0, 0, 0, 0, 0, 0, 0, 0, 0]
    property variant freqs: ["63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    property variant presets: ["flat", "boombox", "bass", "vocal", "night"]
    property variant hpfSteps: [30, 40, 60, 80]
    property string preset: ""
    property bool eqOn: true
    property int hpf: 40
    property real preamp: 0

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
        property color accentInk: "#1b1206"
        property string eqUrl: "http://127.0.0.1:8088/cgi-bin/eq"
    }

    function beep() {
        mySoundUtility.requestSoundBeep(CSoundUtility.BEEPKIND_NORMAL)
    }

    function close() {
        beep()
        if (overlay)
            closed()
        else if (SourceControl.SOURCE_BT_AUDIO !== mySourceControl.sourceType)
            mySourceControl.requestChangeSource(SourceControl.SOURCE_BT_AUDIO)
        else
            myAudioMgr.requestOpenAudioScreen(SourceControl.SOURCE_BT_AUDIO)
    }

    /* "on=1 pre=-4 hpf=40 preset=boombox g=4,3,-1,..." */
    function apply(reply) {
        var fields = reply.replace(/\s+$/, "").split(" ")
        for (var i = 0; i < fields.length; i++) {
            var kv = fields[i].split("=")
            if (kv[0] === "on") eqOn = kv[1] === "1"
            else if (kv[0] === "pre") preamp = Number(kv[1])
            else if (kv[0] === "hpf") hpf = Number(kv[1])
            else if (kv[0] === "preset") preset = kv[1]
            else if (kv[0] === "g") {
                var g = kv[1].split(",")
                for (var j = 0; j < g.length; j++)
                    g[j] = Number(g[j])
                gains = g
            }
        }
    }

    function send(query) {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200 && xhr.responseText.indexOf("error") !== 0)
                eq.apply(xhr.responseText)
        }
        xhr.open("GET", theme.eqUrl + "?" + query)
        xhr.send()
    }

    function label(name) {
        return name.charAt(0).toUpperCase() + name.slice(1)
    }

    function signedDb(v) {
        return (v > 0 ? "+" : "") + v
    }

    Component.onCompleted: send("get")

    /* swallow touches so nothing underneath reacts */
    MouseArea { anchors.fill: parent }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: theme.bgTop }
            GradientStop { position: 1.0; color: theme.bgBottom }
        }
    }

    /* header: big Done button, title, on/off switch, all inset from the edges */
    Rectangle {
        x: 40
        y: 22
        width: 150
        height: 60
        radius: 30
        color: doneTouch.pressed ? "#222a37" : theme.panel
        border.color: theme.line
        border.width: 1
        smooth: true
        Text {
            anchors.centerIn: parent
            text: "Done"
            color: theme.text
            font.family: theme.font
            font.pixelSize: 24
            font.bold: true
        }
        MouseArea {
            id: doneTouch
            anchors.fill: parent
            anchors.margins: -8
            onClicked: eq.close()
        }
    }
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 34
        text: eq.preset === "custom" ? "Equalizer (custom)" : "Equalizer"
        color: theme.text
        font.family: theme.font
        font.pixelSize: 30
        font.bold: true
    }
    Rectangle {
        id: toggle
        x: 800 - 48 - width
        y: 27
        width: 132
        height: 50
        radius: 25
        color: eq.eqOn ? theme.accent : "#2a3140"
        smooth: true
        Behavior on color { ColorAnimation { duration: 150 } }
        Text {
            x: eq.eqOn ? 20 : parent.width - width - 20
            anchors.verticalCenter: parent.verticalCenter
            text: eq.eqOn ? "On" : "Off"
            color: eq.eqOn ? theme.accentInk : theme.textDim
            font.family: theme.font
            font.pixelSize: 22
            font.bold: true
        }
        Rectangle {
            width: 40
            height: 40
            radius: 20
            y: 5
            x: eq.eqOn ? parent.width - width - 5 : 5
            color: eq.eqOn ? theme.accentInk : theme.textDim
            smooth: true
            Behavior on x { NumberAnimation { duration: 150 } }
        }
        MouseArea {
            anchors.fill: parent
            anchors.margins: -8
            onClicked: { eq.beep(); eq.send("on=" + (eq.eqOn ? 0 : 1)) }
        }
    }

    /* presets */
    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 98
        spacing: 12
        Repeater {
            model: eq.presets
            Rectangle {
                property bool active: eq.preset === modelData
                width: 124
                height: 54
                radius: 27
                color: active ? theme.accent : (chipTouch.pressed ? "#222a37" : theme.panel)
                border.color: active ? theme.accent : theme.line
                border.width: 1
                smooth: true
                Text {
                    anchors.centerIn: parent
                    text: eq.label(modelData)
                    color: parent.active ? theme.accentInk : theme.text
                    font.family: theme.font
                    font.pixelSize: 21
                    font.bold: parent.active
                }
                MouseArea {
                    id: chipTouch
                    anchors.fill: parent
                    onClicked: { eq.beep(); eq.send("preset=" + modelData) }
                }
            }
        }
    }

    /* sliders */
    Row {
        x: 58
        y: 164
        opacity: eq.eqOn ? 1.0 : 0.35
        Behavior on opacity { NumberAnimation { duration: 150 } }

        Repeater {
            model: 9
            Item {
                id: band
                property int range: 12
                property real trackHeight: 170
                property real pxPerDb: trackHeight / 2 / range
                property bool dragging: false
                property int dragGain: 0
                property int gain: dragging ? dragGain : (eq.gains[index] === undefined ? 0 : Math.round(eq.gains[index]))
                width: 76
                height: 232

                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: eq.signedDb(band.gain)
                    color: band.gain === 0 ? theme.textFaint : theme.text
                    font.family: theme.font
                    font.pixelSize: 20
                    font.bold: band.dragging
                }

                Item {
                    id: track
                    y: 30
                    width: parent.width
                    height: band.trackHeight

                    Rectangle {          // rail
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 6
                        height: parent.height
                        radius: 3
                        color: theme.line
                    }
                    Rectangle {          // 0 dB tick
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: parent.height / 2 - 1
                        width: 22
                        height: 2
                        color: theme.textFaint
                    }
                    Rectangle {          // fill from 0 dB to the value
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 6
                        radius: 3
                        color: theme.accent
                        y: band.gain >= 0 ? parent.height / 2 - band.gain * band.pxPerDb : parent.height / 2
                        height: Math.abs(band.gain) * band.pxPerDb
                    }
                    Rectangle {          // knob
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: parent.height / 2 - band.gain * band.pxPerDb - height / 2
                        width: band.dragging ? 36 : 30
                        height: width
                        radius: width / 2
                        color: theme.text
                        border.color: theme.accent
                        border.width: band.gain === 0 ? 0 : 3
                        smooth: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        anchors.topMargin: -16
                        anchors.bottomMargin: -16
                        function gainAt(y) {
                            var g = Math.round((track.height / 2 - y) / band.pxPerDb)
                            return Math.max(-band.range, Math.min(band.range, g))
                        }
                        onPressed: {
                            band.dragGain = gainAt(mouse.y)
                            band.dragging = true
                        }
                        onPositionChanged: band.dragGain = gainAt(mouse.y)
                        onReleased: {
                            var g = []
                            for (var i = 0; i < 9; i++)
                                g.push(i === index ? band.dragGain : Math.round(eq.gains[i]))
                            eq.gains = g
                            band.dragging = false
                            eq.send("g=" + g.join(","))
                        }
                    }
                }

                Text {
                    y: 30 + band.trackHeight + 8
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: eq.freqs[index]
                    color: theme.textDim
                    font.family: theme.font
                    font.pixelSize: 18
                }
            }
        }
    }

    /* bass protection (high-pass) and preamp, kept clear of the bottom edge */
    Text {
        x: 48
        y: 408
        text: "Speaker\nprotection"
        color: theme.textDim
        font.family: theme.font
        font.pixelSize: 17
        lineHeight: 0.9
    }
    Row {
        x: 168
        y: 398
        spacing: 10
        Repeater {
            model: eq.hpfSteps
            Rectangle {
                property bool active: eq.hpf === modelData
                width: 100
                height: 50
                radius: 25
                color: active ? "#2c3446" : "transparent"
                border.color: active ? theme.accent : theme.line
                border.width: active ? 2 : 1
                smooth: true
                Text {
                    anchors.centerIn: parent
                    text: modelData + " Hz"
                    color: parent.active ? theme.text : theme.textDim
                    font.family: theme.font
                    font.pixelSize: 19
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: { eq.beep(); eq.send("hpf=" + modelData) }
                }
            }
        }
    }
    Text {
        x: 800 - 48 - width
        y: 412
        text: "Preamp " + eq.signedDb(eq.preamp) + " dB"
        color: theme.textFaint
        font.family: theme.font
        font.pixelSize: 18
    }
}
