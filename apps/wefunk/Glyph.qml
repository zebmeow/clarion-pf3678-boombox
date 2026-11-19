/* Pixel-art icons on a 9x9 grid, drawn as a few rectangles (like the web player's SVGs). */
import QtQuick 1.1

Item {
    id: g
    property string kind: "play"
    property real px: 4
    property color color: "#faffff"
    property color shadow: "#34343e"

    /* [x, y, w, h] in grid cells */
    function shape(k) {
        if (k === "play")  return [[2,1,1,1],[2,2,2,1],[2,3,3,1],[2,4,4,1],[2,5,3,1],[2,6,2,1],[2,7,1,1]]
        if (k === "pause") return [[2,1,2,7],[5,1,2,7]]
        if (k === "prev")  return [[1,1,1,7],[6,1,1,1],[5,2,2,1],[4,3,3,1],[3,4,4,1],[4,5,3,1],[5,6,2,1],[6,7,1,1]]
        if (k === "next")  return [[7,1,1,7],[2,1,1,1],[2,2,2,1],[2,3,3,1],[2,4,4,1],[2,5,3,1],[2,6,2,1],[2,7,1,1]]
        if (k === "up")    return [[4,2,1,1],[3,3,3,1],[2,4,5,1],[1,5,7,1]]
        if (k === "down")  return [[1,3,7,1],[2,4,5,1],[3,5,3,1],[4,6,1,1]]
        if (k === "close") return [[1,1,1,1],[2,2,1,1],[3,3,1,1],[4,4,1,1],[5,5,1,1],[6,6,1,1],[7,7,1,1],
                                   [7,1,1,1],[6,2,1,1],[5,3,1,1],[3,5,1,1],[2,6,1,1],[1,7,1,1]]
        if (k === "list")  return [[1,1,1,1],[3,1,5,1],[1,4,1,1],[3,4,5,1],[1,7,1,1],[3,7,5,1]]
        if (k === "grid")  return [[1,1,3,3],[5,1,3,3],[1,5,3,3],[5,5,3,3]]
        if (k === "disc")  return [[3,1,3,1],[2,2,5,1],[1,3,3,1],[5,3,3,1],[1,4,2,1],[6,4,2,1],[1,5,3,1],[5,5,3,1],[2,6,5,1],[3,7,3,1]]
        return []
    }
    property variant rects: shape(kind)

    width: 9 * px
    height: 9 * px

    Repeater {
        model: g.rects
        Rectangle {
            x: (modelData[0] + 0.5) * g.px
            y: (modelData[1] + 0.5) * g.px
            width: modelData[2] * g.px
            height: modelData[3] * g.px
            color: g.shadow
        }
    }
    Repeater {
        model: g.rects
        Rectangle {
            x: modelData[0] * g.px
            y: modelData[1] * g.px
            width: modelData[2] * g.px
            height: modelData[3] * g.px
            color: g.color
        }
    }
}
