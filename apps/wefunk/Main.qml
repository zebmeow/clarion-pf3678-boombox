/* WEFUNK: plays the WEFUNK Radio show archive stored on the card (/media/map/APPS/wefunk).
 * Look follows the desktop web player (mscplr/player.html); layout follows the head unit's
 * resistive touch panel: nothing tappable within ~40 px of the left/right/bottom edges,
 * big targets, scroll buttons next to every list (flicking is unreliable on the panel).
 *
 * Audio comes from wfplay (/var/local/boombox/wfplay) on http://127.0.0.1:8089, which also
 * serves catalog/*.json. Art and the font load straight from this folder.
 * Opened by ../Apps.qml; emits closed() to go back to it. */
import QtQuick 1.1
import ClarionQt 1.0

Item {
    id: app
    width: 800
    height: 480

    signal closed
    property int tab: 0                 /* 0 shows, 1 playing, 2 tracks */
    property string api: "http://127.0.0.1:8089"

    property variant shows: []          /* catalog/index.json */
    property variant recent: ({})       /* show number -> saved position (ms) */
    property variant cur: ({})          /* catalog/N.json of the loaded show */
    property int curShow: 0
    property int fetchingShow: 0
    property int curIdx: -1

    property string state_: "stopped"
    property real posMs: 0
    property real dur: 0
    property string err: ""
    property bool service: true
    property int fails: 0
    property bool playing: state_ === "playing" || state_ === "loading"

    /* ------------------------------------------------------------ helpers */

    function beep() {
        mySoundUtility.requestSoundBeep(CSoundUtility.BEEPKIND_NORMAL)
    }

    function call(path, done) {
        var x = new XMLHttpRequest()
        x.onreadystatechange = function() {
            if (x.readyState !== 4)
                return
            var d = null
            if (x.status === 200) {
                try { d = JSON.parse(x.responseText) } catch (e) { d = null }
            }
            if (done)
                done(d)
        }
        x.open("GET", api + path)
        x.send()
    }

    function clock(ms) {
        var s = Math.max(0, Math.floor(ms / 1000))
        var h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60
        s = s % 60
        return (h > 0 ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (s < 10 ? "0" : "") + s
    }

    function guest(djs) {
        for (var i = 0; i < djs.length; i++)
            if (djs[i] !== "DJ Static" && djs[i] !== "Professor Groove")
                return djs[i]
        return djs.length ? djs[0] : ""
    }

    function tracks() {
        return cur.tracks === undefined ? [] : cur.tracks
    }

    function findIdx() {
        var t = tracks(), i = 0
        while (i + 1 < t.length && t[i + 1].ms <= posMs)
            i++
        curIdx = t.length ? i : -1
    }

    function track() {
        var t = tracks()
        return curIdx >= 0 && curIdx < t.length ? t[curIdx] : null
    }

    function showArt(n) {
        for (var i = 0; i < shows.length; i++)
            if (shows[i].n === n)
                return shows[i].art
        return []
    }

    function songNumber(i) {          /* talk/intro segments are not numbered */
        var t = tracks(), n = 0
        for (var j = 0; j <= i && j < t.length; j++)
            if (t[j].k === "s")
                n++
        return t[i] !== undefined && t[i].k === "s" ? n : 0
    }

    function apply(d) {
        if (!d) {
            if (++fails >= 3)
                service = false
            return
        }
        fails = 0
        service = true
        state_ = d.state
        posMs = d.pos
        dur = d.dur
        err = d.err
        if (d.show > 0 && d.show !== curShow && d.show !== fetchingShow)
            loadShow(d.show)
        findIdx()
    }

    function loadShow(n) {
        fetchingShow = n
        call("/catalog/" + n + ".json", function(d) {
            fetchingShow = 0
            if (!d)
                return
            cur = d
            curShow = n
            findIdx()
        })
    }

    function loadRecent() {
        call("/recent", function(d) {
            if (!d)
                return
            var m = {}
            for (var i = 0; i < d.length; i++)
                m[String(d[i].show)] = d[i].pos
            recent = m
        })
    }

    /* the speakers only carry the Bluetooth source: switch to it if audio is off.
       (The unit then opens its Bluetooth screen; the music keeps playing.) */
    function speakersOn() {
        if (SourceControl.SOURCE_BT_AUDIO !== mySourceControl.sourceType)
            mySourceControl.requestChangeSource(SourceControl.SOURCE_BT_AUDIO)
    }

    function playShow(n) {
        if (n === curShow) {
            if (!playing) {
                speakersOn()
                call("/resume", apply)
            }
        } else {
            speakersOn()
            call("/play?show=" + n, apply)
        }
        tab = 1
    }

    function toggle() {
        if (playing) {
            call("/pause", apply)
        } else if (curShow > 0) {
            speakersOn()
            call("/resume", apply)
        }
    }

    function seek(ms) {
        posMs = ms
        findIdx()
        call("/seek?pos=" + Math.round(ms), apply)
    }

    function prev() {
        var t = tracks()
        if (curIdx < 0)
            return
        seek(posMs - t[curIdx].ms > 4000 || curIdx === 0 ? t[curIdx].ms : t[curIdx - 1].ms)
    }

    function next() {
        var t = tracks()
        if (curIdx + 1 < t.length)
            seek(t[curIdx + 1].ms)
    }

    Component.onCompleted: {
        call("/catalog/index.json", function(d) {
            if (d)
                shows = d
        })
        loadRecent()
    }

    Timer {
        interval: 500
        running: app.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: app.call("/status", app.apply)
    }

    /* a phone starting to stream needs the audio output back. (A property binding, not
       Connections: Qt 4 refuses the whole screen if a handler names a signal the C++
       object does not have, and its notify signal name is unknown.) */
    property variant btStream: myCBTAudioControl.streamState
    onBtStreamChanged: {
        if (btStream === CBTAudioControl.STREAM_STATE_ON && playing)
            call("/pause", apply)
    }

    /* ------------------------------------------------------------ desk */


    MouseArea { anchors.fill: parent }   /* nothing underneath reacts */

    Rectangle {
        anchors.fill: parent
        color: "#4a3a9e"
    }

    Item {                                 /* the web player's pixel snow, slowed down */
        id: snow
        anchors.fill: parent
        property int tick: 0
        Timer {
            interval: 160
            running: app.visible
            repeat: true
            onTriggered: snow.tick++
        }
        Repeater {
            model: 18
            Rectangle {
                width: index % 4 === 0 ? 4 : 2
                height: width
                color: "#ffffff"
                opacity: 0.55
                x: (index * 151 + 37) % 800
                y: (index * 67 + snow.tick * (1 + index % 3)) % 480
            }
        }
    }

    /* ------------------------------------------------------------ menu bar */

    Rectangle {
        width: parent.width
        height: 84
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#0008a0" }
            GradientStop { position: 0.55; color: "#1c3cf4" }
            GradientStop { position: 1.0; color: "#0a1ec8" }
        }
        Rectangle { y: parent.height - 3; width: parent.width; height: 3; color: "#060a6e" }

        Bevel {
            x: 40; y: 16; width: 150
            glyph: "grid"; glyphPx: 3; label: "Shows"
            latched: app.tab === 0
            onClicked: app.tab = 0
        }
        Bevel {
            x: 202; y: 16; width: 172
            glyph: "disc"; glyphPx: 3; label: "Playing"
            latched: app.tab === 1
            onClicked: app.tab = 1
        }
        Bevel {
            x: 386; y: 16; width: 150
            glyph: "list"; glyphPx: 3; label: "Tracks"
            latched: app.tab === 2
            onClicked: app.tab = 2
        }
        Bevel {
            x: 548; y: 16; width: 88
            glyph: app.playing ? "pause" : "play"
            enabled: app.curShow > 0
            onClicked: app.toggle()
        }
        Bevel {
            x: 800 - 40 - width; y: 16; width: 108
            label: "Exit"
            onClicked: { if (app.playing) app.call("/pause", null); app.closed() }
        }
    }

    /* scroll buttons beside a list (the panel's flick detection is unreliable) */
    Component {
        id: scroller
        Item {
            property variant view
            width: 84
            height: 328
            Bevel {
                width: parent.width; height: 132
                glyph: "up"; glyphPx: 5
                enabled: view !== undefined && view.contentY > 0
                onClicked: view.contentY = Math.max(0, view.contentY - view.height + 40)
            }
            PixText {
                anchors.centerIn: parent
                text: view === undefined || view.contentHeight <= view.height ? "" :
                      Math.round(100 * view.contentY / (view.contentHeight - view.height)) + "%"
                color: "#dcdcec"
            }
            Bevel {
                y: parent.height - height; width: parent.width; height: 132
                glyph: "down"; glyphPx: 5
                enabled: view !== undefined && view.contentY + view.height < view.contentHeight - 1
                onClicked: view.contentY = Math.min(view.contentHeight - view.height, view.contentY + view.height - 40)
            }
        }
    }

    /* ------------------------------------------------------------ shows */

    Win {
        id: showsWin
        visible: app.tab === 0
        x: 40; y: 104; width: 624; height: 328
        title: "WEFUNK Radio"
        titleRight: app.shows.length + " shows"

        GridView {
            id: grid
            anchors.fill: parent
            anchors.leftMargin: 4
            cellWidth: 153
            cellHeight: 145
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: app.shows
            delegate: Item {
                width: 153
                height: 145
                property bool isCur: modelData.n === app.curShow
                property real saved: app.recent[String(modelData.n)] === undefined ? 0 : app.recent[String(modelData.n)]

                Rectangle {          /* frame: yellow on the loaded show */
                    x: 15; y: 4; width: 122; height: 122
                    color: parent.isCur ? "#d8cc2c" : "#5c5cf2"
                }
                Mosaic {
                    x: 18; y: 7; width: 116; height: 116
                    art: modelData.art
                }
                Rectangle {
                    x: 18; y: 7
                    width: badge.paintedWidth + 12; height: 24
                    color: "#0c0c66"
                    PixText {
                        id: badge
                        anchors.centerIn: parent
                        text: "#" + modelData.n
                        color: "#d8cc2c"
                    }
                }
                Rectangle {          /* resume progress */
                    x: 18; y: 117; height: 6
                    visible: parent.saved > 0 && modelData.ms > 0
                    width: 116 * Math.min(1, parent.saved / modelData.ms)
                    color: "#d8cc2c"
                }
                Glyph {
                    x: 112; y: 9
                    visible: parent.isCur && app.playing
                    kind: "play"; px: 2
                    color: "#d8cc2c"
                }
                PixText {
                    x: 6; y: 127; box: 141
                    align: "center"
                    elide: true
                    text: app.guest(modelData.djs)
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: { app.beep(); app.playShow(modelData.n) }
                }
            }
        }
        PixText {
            anchors.centerIn: parent
            visible: app.shows.length === 0
            box: parent.width - 40
            align: "center"
            wrap: true
            text: app.service ? "Loading shows..." : "Player service is not running"
            color: "#9c9cdc"
        }
    }
    Loader {
        visible: app.tab === 0
        x: 676; y: 104
        sourceComponent: scroller
        onLoaded: item.view = grid
    }

    /* ------------------------------------------------------------ playing */

    Win {
        visible: app.tab === 1
        x: 40; y: 104; width: 720; height: 328
        title: app.curShow > 0 ? "Show " + app.curShow + "  " + (app.cur.date === undefined ? "" : app.cur.date) : "Now playing"
        titleRight: app.state_ === "loading" ? "loading" : app.playing ? "playing" : app.curShow > 0 ? "paused" : ""

        Item {
            anchors.fill: parent
            visible: app.curShow > 0

            Rectangle {               /* sunken frame around the art */
                x: 14; y: 14; width: 214; height: 214
                color: "#0c0c66"
                Rectangle { x: 3; y: 211; width: 211; height: 3; color: "#5c5cf2" }
                Rectangle { x: 211; y: 3; width: 3; height: 211; color: "#5c5cf2" }
            }
            Mosaic {
                x: 17; y: 17; width: 208; height: 208
                property variant t: app.track()
                single: t !== null && t.art !== undefined
                art: single ? [t.art] : app.showArt(app.curShow)
            }
            PixText {
                x: 14; y: 240; box: 214
                align: "center"
                property int n: app.songNumber(app.curIdx)
                text: n > 0 ? "Track " + n + " / " + (app.cur.tracks === undefined ? 0 : app.cur.tracks.length) : ""
                color: "#9c9cdc"
            }

            PixText {
                x: 244; y: 14; box: 456
                elide: true
                text: app.err !== "" ? "! " + app.err : (app.cur.djs === undefined ? "" : app.cur.djs.join(", "))
                color: app.err !== "" ? "#d8cc2c" : "#9c9cdc"
            }
            PixText {
                x: 244; y: 44; box: 456
                elide: true
                size: 24
                text: app.track() ? app.track().a : ""
                color: "#d8cc2c"
            }
            PixText {
                x: 244; y: 78; box: 456
                wrap: true
                maxLines: 2
                elide: true
                size: 24
                text: app.track() ? app.track().t : ""
            }

            /* seek bar with a tick per track; tap or drag to move */
            Item {
                id: bar
                x: 244; y: 146; width: 456; height: 40
                property bool dragging: false
                property real dragPos: 0
                property real shown: dragging ? dragPos : app.posMs
                function at(mx) {
                    return Math.max(0, Math.min(1, (mx - 9) / (width - 18))) * app.dur
                }
                Rectangle {
                    y: 10; width: parent.width; height: 20
                    color: "#14147e"
                    Rectangle { width: parent.width; height: 3; color: "#0c0c66" }
                    Rectangle { width: 3; height: parent.height; color: "#0c0c66" }
                    Rectangle {
                        x: 3; y: 3; height: parent.height - 3
                        width: app.dur > 0 ? (parent.width - 6) * bar.shown / app.dur : 0
                        color: "#3c3cf4"
                    }
                }
                Repeater {
                    model: app.dur > 0 ? app.tracks() : []
                    Rectangle {
                        x: 9 + (bar.width - 18) * modelData.ms / app.dur - 1
                        y: 13; width: 2; height: 14
                        color: index === app.curIdx ? "#d8cc2c" : "#6c6cc0"
                    }
                }
                Item {                     /* thumb: a small bevelled button face */
                    x: app.dur > 0 ? (bar.width - 18) * bar.shown / app.dur : 0
                    width: 18; height: 40
                    Rectangle { anchors.fill: parent; color: "#828aa4" }
                    Rectangle { width: 18; height: 3; color: "#c4cde8" }
                    Rectangle { width: 3; height: 40; color: "#c4cde8" }
                    Rectangle { y: 37; width: 18; height: 3; color: "#3b4258" }
                    Rectangle { x: 15; width: 3; height: 40; color: "#3b4258" }
                }
                MouseArea {
                    anchors.fill: parent
                    anchors.topMargin: -10
                    anchors.bottomMargin: -8
                    enabled: app.dur > 0
                    onPressed: { bar.dragPos = bar.at(mouse.x); bar.dragging = true }
                    onPositionChanged: bar.dragPos = bar.at(mouse.x)
                    onReleased: { bar.dragging = false; app.beep(); app.seek(bar.dragPos) }
                }
            }
            PixText {
                x: 244; y: 192
                text: app.clock(bar.shown)
                color: "#9c9cdc"
            }
            PixText {
                x: 700 - paintedWidth; y: 192
                text: app.clock(app.dur)
                color: "#9c9cdc"
            }

            Bevel {
                x: 244; y: 222; width: 124; height: 64
                glyph: "prev"; glyphPx: 5
                onClicked: app.prev()
            }
            Bevel {
                x: 380; y: 222; width: 184; height: 64
                glyph: app.playing ? "pause" : "play"; glyphPx: 5
                label: app.playing ? "Pause" : "Play"
                textSize: 24
                onClicked: app.toggle()
            }
            Bevel {
                x: 576; y: 222; width: 124; height: 64
                glyph: "next"; glyphPx: 5
                onClicked: app.next()
            }
        }

        Column {
            anchors.centerIn: parent
            visible: app.curShow === 0
            spacing: 24
            PixText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: app.err !== "" ? "! " + app.err : app.service ? "Nothing playing" : "Player service is not running"
                color: app.err !== "" ? "#d8cc2c" : "#dcdcec"
                size: app.err !== "" ? 16 : 24
            }
            Bevel {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 260; height: 64
                glyph: "grid"; glyphPx: 4
                label: "Pick a show"
                textSize: 24
                onClicked: app.tab = 0
            }
        }
    }

    /* ------------------------------------------------------------ tracks */

    Win {
        visible: app.tab === 2
        x: 40; y: 104; width: 624; height: 328
        title: app.curShow > 0 ? "Tracks  show " + app.curShow : "Tracks"
        titleRight: app.cur.tracks === undefined ? "" : app.cur.tracks.length + " items"

        ListView {
            id: list
            anchors.fill: parent
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: app.tracks()
            /* keep the current track in view as the show plays, unless the list is being moved */
            property int follow: visible && count > 0 ? app.curIdx : -1
            onFollowChanged: if (follow >= 0 && !moving) positionViewAtIndex(follow, ListView.Center)
            delegate: Item {
                width: list.width
                height: 58
                property bool isCur: index === app.curIdx
                Rectangle {
                    anchors.fill: parent
                    color: parent.isCur ? "#3c3cf4" : (rowTouch.pressed ? "#2e2ed2" : "transparent")
                }
                Rectangle { y: 57; width: parent.width; height: 1; color: "#14147e" }
                PixText {
                    x: 10; y: 19; box: 40
                    property int n: app.songNumber(index)
                    text: n > 0 ? String(n) : "-"
                    color: "#9c9cdc"
                }
                PixText {
                    x: 56; y: 8; box: parent.width - 56 - 96
                    elide: true
                    text: modelData.a
                    color: "#d8cc2c"
                }
                PixText {
                    x: 56; y: 31; box: parent.width - 56 - 96
                    elide: true
                    text: modelData.t
                }
                PixText {
                    x: parent.width - 12 - paintedWidth; y: 19
                    text: app.clock(modelData.ms)
                    color: "#9c9cdc"
                }
                MouseArea {
                    id: rowTouch
                    anchors.fill: parent
                    onClicked: { app.beep(); app.seek(modelData.ms); app.tab = 1 }
                }
            }
        }
        PixText {
            anchors.centerIn: parent
            visible: app.curShow === 0
            text: "Pick a show first"
            color: "#9c9cdc"
        }
    }
    Loader {
        visible: app.tab === 2
        x: 676; y: 104
        sourceComponent: scroller
        onLoaded: item.view = list
    }
}
