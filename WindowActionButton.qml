import QtQuick
import QtQuick.Controls

Button {
    id: control
    required property var colors
    width: parent.width
    padding: 10
    hoverEnabled: true
    contentItem: Text { textFormat: Text.PlainText;
        text: control.text
        font.family: control.colors.fontFamily
        font.pixelSize: 13 * control.colors.fontSize / 12
        color: control.enabled ? control.colors.foreground : control.colors.muted
        elide: Text.ElideRight
    }
    background: Rectangle {
        radius: 6
        color: control.down || control.highlighted ? control.colors.selected : control.hovered ? control.colors.hover : "transparent"
    }
}
