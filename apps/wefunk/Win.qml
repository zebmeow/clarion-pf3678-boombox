/* The web player's window (.win): blue body, bevelled edge, grey title bar, hard shadow.
 * Children go into the body below the title bar. */
import QtQuick 1.1

Item {
    id: w
    property string title: ""
    property string titleRight: ""
    default property alias content: body.children

    Rectangle {           /* box-shadow: 10px 10px 0 */
        x: 10
        y: 10
        width: parent.width
        height: parent.height
        color: "#2a1f68"
    }
    Rectangle {
        anchors.fill: parent
        color: "#2424b4"
    }
    Rectangle { width: parent.width; height: 3; color: "#5c5cf2" }
    Rectangle { width: 3; height: parent.height; color: "#5c5cf2" }
    Rectangle { y: parent.height - 3; width: parent.width; height: 3; color: "#0c0c66" }
    Rectangle { x: parent.width - 3; width: 3; height: parent.height; color: "#0c0c66" }

    Rectangle {
        id: bar
        x: 3
        y: 3
        width: parent.width - 6
        height: 32
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#bdc6e1" }
            GradientStop { position: 0.45; color: "#929ab4" }
            GradientStop { position: 1.0; color: "#5d647c" }
        }
        PixText {
            x: 10
            box: parent.width - 20 - right.paintedWidth
            anchors.verticalCenter: parent.verticalCenter
            text: w.title
            color: "#eaeffd"
            shadow: "#30303a"
            size: 16
            elide: true
        }
        PixText {
            id: right
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: w.titleRight
            color: "#eaeffd"
            shadow: "#30303a"
            size: 16
        }
    }

    Item {
        id: body
        x: 3
        y: bar.y + bar.height
        width: parent.width - 6
        height: parent.height - y - 3
        clip: true
    }
}
