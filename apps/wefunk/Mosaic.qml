/* A show's cover: 2x2 artist photos, like the web player's show tiles. */
import QtQuick 1.1

Item {
    id: m
    property variant art: []      /* up to 4 artist slugs */
    property bool single: false   /* one photo filling the square */
    property int cell: single ? width : width / 2

    Rectangle {
        anchors.fill: parent
        color: "#0c0c66"
    }
    Grid {
        columns: 2
        Repeater {
            model: m.single ? 1 : 4
            Item {
                width: m.cell
                height: m.cell
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    color: index % 3 === 0 ? "#14147e" : "#2a1f68"
                    Glyph {
                        anchors.centerIn: parent
                        kind: "disc"
                        px: 3
                        color: "#3c3cf4"
                        shadow: "#0c0c66"
                        visible: m.art[index] === undefined
                    }
                }
                Image {
                    anchors.fill: parent
                    anchors.margins: 1
                    source: m.art[index] === undefined ? "" : "art/" + m.art[index] + ".jpg"
                    sourceSize.width: m.cell
                    sourceSize.height: m.cell
                    fillMode: Image.PreserveAspectCrop
                    smooth: true
                }
            }
        }
    }
}
