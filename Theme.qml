import QtQuick
import Quickshell.Io

QtObject {
    id: theme
    property bool active: false
    property color background: "#151515"
    property color foreground: "#eeeeee"
    property color accent: "#eeeeee"
    property string fontFamily: "monospace"
    property real fontSize: 12
    readonly property color surface: mix(background, foreground, 0.045)
    readonly property color raised: mix(background, foreground, 0.085)
    readonly property color muted: mix(background, foreground, 0.57)
    readonly property color border: mix(background, foreground, 0.2)
    readonly property color hover: mix(background, accent, 0.14)
    readonly property color selected: mix(background, accent, 0.09)
    function mix(base, tint, amount) {
        return Qt.rgba(base.r * (1 - amount) + tint.r * amount,
                       base.g * (1 - amount) + tint.g * amount,
                       base.b * (1 - amount) + tint.b * amount, 1);
    }
    function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity); }
    function reload() { if (!reader.running) reader.running = true; }
    Component.onCompleted: reload()
    onActiveChanged: if (active) reload()
    property Timer poll: Timer {
        interval: 2000
        repeat: true
        running: theme.active
        onTriggered: theme.reload()
    }
    property Process reader: Process {
        command: ["python", Qt.resolvedUrl("read-theme.py").toString().replace("file://", "")]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(text);
                    theme.background = data.background;
                    theme.foreground = data.foreground;
                    theme.accent = data.accent;
                    theme.fontFamily = data.fontFamily;
                    theme.fontSize = data.fontSize;
                } catch (error) { console.warn("Atlas could not refresh the theme:", error); }
            }
        }
    }
}
