/*******************************************************************************
    File Name   : SXMTopScreen.qml
    Summary     : Boombox BLUETOOTH screen: pairing mode + remembered phones. Lives
                  in the SiriusXM screen's slot (bundle patched in place; SiriusXM
                  is unreachable on the boombox). Opened from the now-playing screen.

                  Pairing works like a speaker, not a car: "Pair new phone" uses a
                  free device slot, or forgets the oldest phone that is not connected
                  when all slots are full, then shows the code to confirm. Built on
                  the stock flow: requestConnectBTDevice(emptySlot) starts pairing;
                  notifyNumericComparison / notifyRegistPinCode / notifyPasskeyUpdated
                  show a code; requestConfirmPinCode / requestCancelConfirmPinCode
                  answer; notifyRegistComplete / notifyRegistrationFailed end it.
                  Forget: requestConfirmDeleteBTDeviceInfo(slot) -> notifyDeleteDevice
                  -> requestDeleteBTDevice() -> notifyDeleteComplete.
*******************************************************************************/
import QtQuick 1.1
import ClarionQt 1.0

Item {
    id: bt
    width: 800
    height: 480
    property bool overlay: false
    signal closed

    /* idle | waiting | confirm | pin | busy | done | failed */
    property string mode: "idle"
    property string code: ""
    property string peer: ""
    property int freeingSlot: -1      // slot being emptied to make room for pairing
    property bool forgetting: false

    QtObject {
        id: theme
        property string font: myTextStyle.getFontName(TextStyle.FP_AUDIO_TOPINFO_TITLE, 0)
        property color panel: "#141922"
        property color line: "#283040"
        property color text: "#f4f6fa"
        property color textDim: "#a9b1bf"
        property color textFaint: "#687183"
        property color accent: "#ffb547"
        property color accentInk: "#1b1206"
    }

    function beep() {
        mySoundUtility.requestSoundBeep(CSoundUtility.BEEPKIND_NORMAL)
    }

    function close() {
        beep()
        if (mode === "waiting" || mode === "confirm" || mode === "pin")
            myCBTPhoneControl.requestCancelConfirmPinCode()
        if (overlay)
            closed()
        else
            myAudioMgr.requestOpenAudioScreen(SourceControl.SOURCE_BT_AUDIO)
    }

    /* the device slots, read from the Repeater's delegates */
    function deviceSlots() {
        var out = []
        for (var i = 0; i < deviceColumn.children.length; i++) {
            var c = deviceColumn.children[i]
            if (c.isSlot)
                out.push(c)
        }
        return out
    }

    function startPairing() {
        myCBTPhoneControl.requestPairedDeviceInfo()
        var all = deviceSlots()
        for (var i = 0; i < all.length; i++) {
            if (!all[i].used) {
                pairInto(all[i].slot)
                return
            }
        }
        /* all slots taken: forget the first phone that is not the connected one */
        for (var j = 0; j < all.length; j++) {
            if (all[j].slot !== myCBTPhoneControl.connectionDeviceSlotID) {
                freeingSlot = all[j].slot
                forgetting = true
                mode = "busy"
                myCBTPhoneControl.requestConfirmDeleteBTDeviceInfo(freeingSlot)
                return
            }
        }
        mode = "failed"
    }

    function pairInto(slot) {
        code = ""
        peer = ""
        mode = "waiting"
        myCBTPhoneControl.requestConnectBTDevice(slot)
    }

    function forget(slot) {
        beep()
        forgetting = true
        freeingSlot = -1
        myCBTPhoneControl.requestConfirmDeleteBTDeviceInfo(slot)
    }

    Component.onCompleted: myCBTPhoneControl.requestPairedDeviceInfo()

    Connections {
        target: myCBTPhoneControl
        ignoreUnknownSignals: true
        onNotifyNumericComparison: { bt.code = strPasskey; bt.mode = "confirm" }
        onNotifyRegistPinCode: { bt.code = strPasskey; bt.peer = strDeviceName; bt.mode = "pin" }
        onNotifyPasskeyUpdated: { bt.code = strPasskey; bt.mode = "pin" }
        onNotifyReplyAuthenticationSuccess: bt.mode = "busy"
        onNotifyRegistComplete: {
            bt.peer = strDeviceName
            bt.mode = "done"
            myCBTPhoneControl.requestPairedDeviceInfo()
            doneTimer.start()
        }
        onNotifyRegistrationFailed: bt.mode = "failed"
        onNotifyCancelRegistrationDeviceSuccess: bt.mode = "idle"
        /* our own Forget button already asked, so confirm the stock prompt directly */
        onNotifyDeleteDevice: if (bt.forgetting) myCBTPhoneControl.requestDeleteBTDevice()
        onNotifyDeleteComplete: {
            bt.forgetting = false
            myCBTPhoneControl.requestPairedDeviceInfo()
            if (bt.freeingSlot >= 0) {
                var s = bt.freeingSlot
                bt.freeingSlot = -1
                bt.pairInto(s)
            }
        }
    }
    Timer {
        id: doneTimer
        interval: 2500
        onTriggered: bt.close()
    }

    MouseArea { anchors.fill: parent }   // nothing underneath should react

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#151a24" }
            GradientStop { position: 1.0; color: "#07080b" }
        }
    }

    /* header (inset from the edges) */
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
            onClicked: bt.close()
        }
    }
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 34
        text: "Bluetooth"
        color: theme.text
        font.family: theme.font
        font.pixelSize: 30
        font.bold: true
    }

    /* left: connection state and pairing */
    Column {
        x: 48
        y: 116
        width: 330
        spacing: 12

        Text {
            width: parent.width
            text: myCBTPhoneControl.connectionDeviceName !== "" ? "Connected to" : "No phone connected"
            color: theme.textDim
            font.family: theme.font
            font.pixelSize: 20
        }
        Text {
            width: parent.width
            visible: myCBTPhoneControl.connectionDeviceName !== ""
            text: myCBTPhoneControl.connectionDeviceName
            color: theme.text
            font.family: theme.font
            font.pixelSize: 30
            font.bold: true
            elide: Text.ElideRight
        }
        Item { width: 1; height: 10 }
        Rectangle {
            width: 300
            height: 72
            radius: 36
            color: pairTouch.pressed ? "#c9741c" : theme.accent
            smooth: true
            Text {
                anchors.centerIn: parent
                text: "Pair new phone"
                color: theme.accentInk
                font.family: theme.font
                font.pixelSize: 25
                font.bold: true
            }
            MouseArea {
                id: pairTouch
                anchors.fill: parent
                onClicked: { bt.beep(); bt.startPairing() }
            }
        }
        Text {
            width: parent.width
            text: "Remembered phones reconnect by themselves. When the list is full, pairing forgets the oldest one."
            color: theme.textFaint
            font.family: theme.font
            font.pixelSize: 17
            wrapMode: Text.WordWrap
        }
    }

    /* right: remembered phones */
    Text {
        x: 420
        y: 116
        text: "Remembered phones"
        color: theme.textDim
        font.family: theme.font
        font.pixelSize: 20
    }
    Column {
        id: deviceColumn
        x: 420
        y: 152
        width: 340
        spacing: 8
        Repeater {
            model: myDeviceListModel
            Rectangle {
                property bool isSlot: true
                property int slot: index
                property bool used: slotStatus
                width: 340
                height: used ? 56 : 0
                visible: used
                radius: 14
                color: theme.panel
                border.color: theme.line
                border.width: 1
                Text {
                    x: 18
                    anchors.verticalCenter: parent.verticalCenter
                    width: 170
                    text: deviceName
                    color: theme.text
                    font.family: theme.font
                    font.pixelSize: 21
                    elide: Text.ElideRight
                }
                Rectangle {
                    x: parent.width - width - 8
                    anchors.verticalCenter: parent.verticalCenter
                    width: 118
                    height: 44
                    radius: 22
                    color: forgetTouch.pressed ? "#3a2020" : "transparent"
                    border.color: "#6b3a3a"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "Forget"
                        color: "#e8a0a0"
                        font.family: theme.font
                        font.pixelSize: 19
                    }
                    MouseArea {
                        id: forgetTouch
                        anchors.fill: parent
                        anchors.margins: -6
                        onClicked: bt.forget(slot)
                    }
                }
            }
        }
    }

    /* pairing panel: covers the screen while pairing is in progress */
    Rectangle {
        anchors.fill: parent
        visible: bt.mode !== "idle"
        color: "#f5080a0e"
        MouseArea { anchors.fill: parent }

        Column {
            anchors.centerIn: parent
            width: 600
            spacing: 18

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: bt.mode === "waiting" ? "Pairing mode is on" :
                      bt.mode === "confirm" ? "Does your phone show this code?" :
                      bt.mode === "pin" ? "Enter this code on your phone" :
                      bt.mode === "busy" ? "One moment..." :
                      bt.mode === "done" ? "Paired" : "Pairing did not work"
                color: theme.text
                font.family: theme.font
                font.pixelSize: 32
                font.bold: true
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                visible: bt.mode === "confirm" || bt.mode === "pin"
                text: bt.code
                color: theme.accent
                font.family: theme.font
                font.pixelSize: 64
                font.bold: true
                font.letterSpacing: 6
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: bt.mode === "waiting" ? "On your phone, open Bluetooth settings and pick this boombox from the list." :
                      bt.mode === "done" ? bt.peer :
                      bt.mode === "failed" ? "Make sure Bluetooth is on and the phone is close, then try again." : ""
                visible: text !== ""
                color: theme.textDim
                font.family: theme.font
                font.pixelSize: 22
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 24
                visible: bt.mode !== "busy" && bt.mode !== "done"
                Rectangle {
                    width: 200
                    height: 68
                    radius: 34
                    visible: bt.mode === "confirm" || bt.mode === "failed"
                    color: okTouch.pressed ? "#c9741c" : theme.accent
                    Text {
                        anchors.centerIn: parent
                        text: bt.mode === "failed" ? "Try again" : "Pair"
                        color: theme.accentInk
                        font.family: theme.font
                        font.pixelSize: 24
                        font.bold: true
                    }
                    MouseArea {
                        id: okTouch
                        anchors.fill: parent
                        onClicked: {
                            bt.beep()
                            if (bt.mode === "failed") {
                                bt.startPairing()
                            } else {
                                bt.mode = "busy"
                                myCBTPhoneControl.requestConfirmPinCode()
                            }
                        }
                    }
                }
                Rectangle {
                    width: 200
                    height: 68
                    radius: 34
                    color: cancelTouch.pressed ? "#222a37" : theme.panel
                    border.color: theme.line
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: bt.mode === "failed" ? "Close" : "Cancel"
                        color: theme.text
                        font.family: theme.font
                        font.pixelSize: 24
                    }
                    MouseArea {
                        id: cancelTouch
                        anchors.fill: parent
                        onClicked: {
                            bt.beep()
                            if (bt.mode !== "failed")
                                myCBTPhoneControl.requestCancelConfirmPinCode()
                            bt.mode = "idle"
                        }
                    }
                }
            }
        }
    }
}
