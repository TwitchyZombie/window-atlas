import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "."

Item {
    id: app
    property var shell: null
    property var manifest: null
    function open(payloadJson) { if (!opened) toggle(); }
    function close() { opened = false; cancelDrag(); }
    function dismiss() { close(); }
    Theme { id: theme; active: app.opened }
    Settings {
        id: preferences
        location: StandardPaths.writableLocation(StandardPaths.GenericConfigLocation) + "/window-atlas.ini"
        property int desktopCount: 4
        property string workspaceNames: "{}"
        property string savedArrangement: "[]"
    }
    function parseJson(text, fallback) { try { return JSON.parse(text); } catch (error) { return fallback; } }
    readonly property var workspaceNames: parseJson(preferences.workspaceNames, {})
    readonly property var savedArrangement: parseJson(preferences.savedArrangement, [])
    function workspaceName(id) { return workspaceNames[String(id)] || "Desktop " + id; }
    function renameWorkspace(id, name) {
        const names = Object.assign({}, workspaceNames);
        name = name.trim().slice(0, 40);
        if (name) names[String(id)] = name; else delete names[String(id)];
        preferences.workspaceNames = JSON.stringify(names);
    }
    property var selectedAddresses: []
    function toggleSelected(w) {
        const addresses = selectedAddresses.slice();
        const index = addresses.indexOf(w.address);
        if (index < 0) addresses.push(w.address); else addresses.splice(index, 1);
        selectedAddresses = addresses;
    }
    function groupFor(w) {
        if (!w) return [];
        return selectedAddresses.indexOf(w.address) >= 0 ? allWindows.filter(item => selectedAddresses.indexOf(item.address) >= 0) : [w];
    }
    function escapeOverview() {
        if (selectedAddresses.length) selectedAddresses = [];
        else { opened = false; cancelDrag(); }
    }
    property var undoMoves: []
    property string operation: ""
    readonly property bool busy: mover.running || pendingWindow !== null
    function runTool(action, payload) {
        if (busy) { notice = "Please wait for the current operation"; return false; }
        operation = action;
        const command = ["python", Qt.resolvedUrl("workspace-tools.py").toString().replace("file://", ""), action === "undo" ? "move" : action];
        const json = JSON.stringify(payload);
        if (action === "restore") mover.restoreInput = json;
        else command.push(json);
        mover.command = command;
        mover.running = true;
        return true;
    }
    function undoLastMove() {
        if (!undoMoves.length || busy) return;
        notice = "Undoing the last move…";
        runTool("undo", undoMoves.map(item => ({address: item.address, to: item.from, pid: item.pid})));
    }
    Timer { id: undoExpiry; interval: 15000; onTriggered: app.undoMoves = [] }
    function storeArrangement(slots) {
        preferences.savedArrangement = JSON.stringify(slots);
        preferences.sync();
    }
    function saveArrangement(group) {
        if (busy) return;
        storeArrangement((group || allWindows).map(w => {
            const entry = entryForWindow(w);
            const data = w.lastIpcObject;
            return {classes: [data.class || "", data.initialClass || ""], title: w.title || "", workspace: w.workspace.id,
                desktopId: entry ? entry.id : "", name: entry ? entry.name : data.class || "Window"};
        }));
        notice = "Saved " + savedArrangement.length + " windows in this arrangement";
    }
    function restoreArrangement(openMissing) {
        if (!savedArrangement.length || busy) return;
        notice = "Restoring the saved app groups…";
        runTool("restore", {slots: savedArrangement, openMissing: openMissing});
    }
    function launchOnWorkspace(entry, id) {
        if (!entry || busy) return;
        notice = "Opening " + entry.name + " on " + workspaceName(id) + "…";
        runTool("launch", {desktopId: entry.id, workspace: id, classes: [entry.id, entry.startupClass, entry.id.replace(/\.desktop$/, "")]});
    }
    readonly property int desktopCount: [0, 2, 4, 8].indexOf(preferences.desktopCount) >= 0 ? preferences.desktopCount : 4
    property bool opened: false
    property bool selecting: false
    onOpenedChanged: if (!opened) { windowActions.close(); desktopActions.close(); launcher.close(); arrangementMenu.close(); renameDialog.close(); }
    onAllWindowsChanged: {
        if (windowActions.targetWindow && allWindows.indexOf(windowActions.targetWindow) < 0) windowActions.close();
        selectedAddresses = selectedAddresses.filter(address => allWindows.some(w => w.address === address));
    }
    // Keep the surface mapped until the short exit animation finishes.
    property real reveal: opened ? 1 : 0
    Behavior on reveal {
        NumberAnimation {
            duration: Style.duration(app.opened ? 140 : 110)
            easing.type: Easing.OutCubic
        }
    }
    property string query: ""
    readonly property var appEntries: {
        const entries = {};
        for (const entry of DesktopEntries.applications.values) {
            for (const key of [entry.id, entry.startupClass]) {
                if (key) entries[String(key).toLowerCase().replace(/\.desktop$/, "")] = entry;
            }
        }
        return entries;
    }
    function entryForWindow(w) {
        const data = w.lastIpcObject;
        for (const key of [data.class, data.initialClass]) {
            const entry = appEntries[String(key || "").toLowerCase().replace(/\.desktop$/, "")];
            if (entry) return entry;
        }
        return null;
    }
    function appIcon(entry) {
        const icon = entry ? entry.icon : "";
        if (icon.startsWith("/")) return "file://" + icon;
        if (icon.startsWith("file://") || icon.startsWith("image://")) return icon;
        return Quickshell.iconPath(icon || "application-x-executable", true)
            || Quickshell.iconPath("application-x-executable", true);
    }
    property int keyboardIndex: -1
    onDesktopTilesChanged: keyboardIndex = -1
    function navigateDesktop(key) {
        if (query.length || draggedWindow) return false;
        if ([Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down].indexOf(key) < 0) return false;
        let index = keyboardIndex;
        if (index < 0) {
            index = desktopTiles.indexOf(Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1);
            if (index < 0) index = 0;
        }
        const columns = canvas.columns;
        if (key === Qt.Key_Left && index % columns > 0) index--;
        if (key === Qt.Key_Right && index % columns < columns - 1) index = Math.min(desktopTiles.length - 1, index + 1);
        if (key === Qt.Key_Up && index >= columns) index -= columns;
        if (key === Qt.Key_Down && index + columns < desktopTiles.length) index += columns;
        keyboardIndex = index;
        return true;
    }
    function confirmSelection() {
        const tile = desktops.itemAt(keyboardIndex);
        if (!query.length && tile) focusWorkspace(tile.workspaceId);
        else if (windows.length) focusWindow(windows[0]);
    }
    property string notice: "Grab a window and drop it onto another desktop"
    property var draggedWindow: null
    property point pressPoint: Qt.point(0, 0)
    property point pointerPoint: Qt.point(0, 0)
    property bool dragging: false
    property int dropWorkspace: -1
    property int hoverWorkspace: -1
    property var pendingWindow: null
    property int pendingWorkspace: -1
    property bool moveConfirmed: false
    property int completedWorkspace: -1
    function clearMoveFeedback() {
        if (notice === "Moved to Desktop " + completedWorkspace)
            notice = "Grab a window and drop it onto another desktop";
        completedWorkspace = -1;
        moveFeedback.stop();
    }
    Timer {
        id: moveFeedback
        interval: 1600
        onTriggered: app.clearMoveFeedback()
    }
    property int syncTicks: 0
    property int stableTicks: 0
    property var allWindows: Hyprland.toplevels.values.filter(w => w === pendingWindow || (w.workspace && w.workspace.id > 0))
    property var windows: allWindows.filter(w => {
        const entry = entryForWindow(w);
        return ((w.title || "") + " " + (w.lastIpcObject.class || "") + " " + (entry ? entry.name : "")).toLowerCase().includes(query.toLowerCase());
    })
    property var occupiedWorkspaces: {
        const ids = allWindows.map(w => w === pendingWindow && pendingWorkspace > 0 ? pendingWorkspace : w.workspace ? w.workspace.id : -1).filter(id => id > 0);
        return Array.from(new Set(ids)).sort((a, b) => a - b);
    }
    property int newWorkspaceId: {
        let id = 1;
        while (displayedWorkspaces.indexOf(id) >= 0) id++;
        return id;
    }
    readonly property var displayedWorkspaces: {
        const ids = occupiedWorkspaces.slice();
        for (let id = 1; id <= desktopCount; id++) ids.push(id);
        return Array.from(new Set(ids)).sort((a, b) => a - b);
    }
    property var desktopTiles: displayedWorkspaces.concat([0])
    function toggle() {
        clearMoveFeedback();
        keyboardIndex = -1;
        selectedAddresses = [];
        selecting = false;
        opened = !opened;
        cancelDrag();
        if (opened) { query = ""; search.text = ""; Hyprland.refreshMonitors(); Hyprland.refreshToplevels(); search.forceActiveFocus(); }
    }
    property bool monitorRefreshNeeded: false
    function scheduleRefresh(monitors) {
        if (!opened) return;
        monitorRefreshNeeded = monitorRefreshNeeded || monitors;
        if (!eventRefresh.running) eventRefresh.start();
    }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (!app.opened) return;
            const name = String(event.name);
            const monitors = name.indexOf("monitor") >= 0 || name === "configreloaded";
            if (monitors || /^(openwindow|closewindow|movewindow|windowtitle|activewindow|workspace|focusedmon|fullscreen|changefloatingmode|moveworkspace|activespecial)/.test(name))
                app.scheduleRefresh(monitors);
        }
    }
    Timer {
        id: eventRefresh
        interval: 80
        onTriggered: {
            if (!app.opened) return;
            if (app.draggedWindow) return;
            if (app.monitorRefreshNeeded) Hyprland.refreshMonitors();
            app.monitorRefreshNeeded = false;
            Hyprland.refreshToplevels();
        }
    }
    onDraggedWindowChanged: if (!draggedWindow && opened) scheduleRefresh(false)
    Timer {
        // Geometry changes do not all emit IPC events; retain a quiet fallback.
        interval: 1000
        repeat: true
        running: app.opened && !app.draggedWindow && !app.pendingWindow
        onTriggered: app.scheduleRefresh(false)
    }
    function cancelDrag() { draggedWindow = null; dragging = false; dropWorkspace = -1; hoverWorkspace = -1; }
    function focusWindow(w) {
        selecting = true;
        opened = false;
        Qt.callLater(function() { if (w.wayland) w.wayland.activate(); });
    }
    function focusWorkspace(id) {
        selecting = true;
        opened = false;
        Qt.callLater(function() {
            Quickshell.execDetached(["hyprctl", "eval", 'hl.dispatch(hl.dsp.focus({workspace="' + id + '"}))']);
        });
    }
    function beginDrag(w, x, y) {
        if (busy) { notice = "Finishing the previous operation…"; return; }
        clearMoveFeedback();
        draggedWindow = w;
        pressPoint = Qt.point(x, y);
        pointerPoint = pressPoint;
        dragging = false;
    }
    function updateDrag(x, y) {
        if (!draggedWindow) return;
        pointerPoint = Qt.point(x, y);
        if (Math.hypot(x - pressPoint.x, y - pressPoint.y) > 10) dragging = true;
        dropWorkspace = -1;
        if (!dragging) return;
        for (let i = 0; i < desktops.count; i++) {
            const tile = desktops.itemAt(i);
            const p = tile.mapFromItem(overlay.contentItem, x, y);
            if (p.x >= 0 && p.y >= 0 && p.x < tile.width && p.y < tile.height) {
                dropWorkspace = tile.workspaceId;
                if (tile.isNew) {
                    hoverWorkspace = tile.workspaceId;
                    notice = "Desktop " + hoverWorkspace + " is ready — release to move the window here";
                }
                break;
            }
        }
    }
    function finishDrag(x, y) {
        if (!draggedWindow) return;
        updateDrag(x, y);
        const w = draggedWindow;
        const moved = dragging;
        const destination = dropWorkspace;
        cancelDrag();
        if (!moved) { focusWindow(w); return; }
        if (destination < 1) { notice = "Move cancelled — drop inside a desktop square"; return; }
        moveWindows(groupFor(w), destination);
    }
    function moveWindow(w, destination) {
        moveWindows([w], destination);
    }
    function moveWindows(group, destination) {
        if (busy) { notice = "Please wait for the previous operation"; return; }
        group = group.filter(w => w && allWindows.indexOf(w) >= 0 && w.workspace && w.workspace.id !== destination);
        if (!group.length) { notice = "The selected windows are already there or have closed"; return; }
        const w = group[0];
        if (!w || allWindows.indexOf(w) < 0) { notice = "That window has closed"; return; }
        if (pendingWindow || mover.running) { notice = "Please wait for the previous move"; return; }
        clearMoveFeedback();
        if (w.workspace && w.workspace.id === destination) { notice = "Window is already on Desktop " + destination; return; }
        pendingWindow = w;
        pendingWorkspace = destination;
        moveConfirmed = false;
        syncTicks = 0;
        stableTicks = 0;
        notice = "Moving window to Desktop " + destination + "…";
        operation = "move";
        mover.command = ["python", Qt.resolvedUrl("workspace-tools.py").toString().replace("file://", ""), "move", JSON.stringify(group.map(item => ({address: item.address, to: destination, pid: item.lastIpcObject.pid})))];
        mover.running = true;
    }
    function clearPendingMove() {
        pendingWindow = null;
        pendingWorkspace = -1;
        moveConfirmed = false;
    }
    Timer {
        interval: 50
        repeat: true
        running: app.pendingWindow !== null
        onTriggered: {
            app.syncTicks++;
            if (app.moveConfirmed && app.pendingWindow.workspace && app.pendingWindow.workspace.id === app.pendingWorkspace) {
                app.stableTicks++;
                if (app.stableTicks >= 3) app.clearPendingMove();
            } else app.stableTicks = 0;
            if (app.pendingWindow && app.syncTicks % 5 === 0) {
                Hyprland.refreshWorkspaces();
                Hyprland.refreshToplevels();
            }
            if (app.pendingWindow && app.syncTicks >= 100 && !mover.running) {
                app.notice = "Workspace information took too long to refresh — reopen Atlas to check";
                app.clearPendingMove();
            }
        }
    }
    Process {
        id: mover
        property string restoreInput: ""
        stdinEnabled: true
        onStarted: {
            if (app.operation === "restore") {
                write(restoreInput + "\n");
            }
            restoreInput = "";
        }
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const result = JSON.parse(text);
                    const moves = result.moves || [];
                    if (moves.length && app.operation !== "launch") {
                        app.undoMoves = app.operation === "undo" ? [] : moves;
                        if (app.undoMoves.length) undoExpiry.restart(); else undoExpiry.stop();
                    }
                    if (result.ok && app.operation === "move") {
                        const destination = moves.length ? moves[0].to : app.pendingWorkspace;
                        app.notice = "Moved to Desktop " + destination;
                        app.moveConfirmed = true;
                        app.completedWorkspace = destination;
                        moveFeedback.restart();
                        app.selectedAddresses = [];
                    } else {
                        app.notice = result.ok ? app.operation === "undo" ? "Move undone" : app.operation === "launch" ? "App opened on " + app.workspaceName(result.workspace)
                            : "Arrangement restored" + (result.missing && result.missing.length ? " · " + result.missing.length + " apps were not opened" : "")
                            : "Operation incomplete: " + result.error;
                        app.clearPendingMove();
                    }
                    Hyprland.refreshWorkspaces();
                    Hyprland.refreshToplevels();
                } catch (e) {
                    app.notice = "Move failed — could not read compositor response";
                    app.clearPendingMove();
                }
            }
        }
        stderr: StdioCollector {}
    }
    IpcHandler {
        target: "io.github.twitchyzombie.window-atlas"
        function status(): string {
            return JSON.stringify({opened: app.opened, windows: app.allWindows.length,
                toplevels: Hyprland.toplevels.values.map(w => ({address: w.address, workspace: w.workspace ? w.workspace.id : null, ipc: w.lastIpcObject})),
                tiles: app.desktopTiles});
        }
        function toggle(): void { app.toggle(); }
        function close(): void { app.opened = false; app.cancelDrag(); }
    }

    PanelWindow {
        id: overlay
        visible: app.opened || (!app.selecting && app.reveal > 0)
        screen: Quickshell.screens[0]
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "window-overview"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: app.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        color: theme.alpha(theme.background, 0.97 * app.reveal)
        contentItem.focus: true
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.MiddleButton
            onClicked: { app.opened = false; app.cancelDrag(); }
        }
        ColumnLayout {
            opacity: app.reveal
            scale: 0.975 + 0.025 * app.reveal
            transformOrigin: Item.Center
            enabled: app.opened
            anchors.fill: parent
            anchors.margins: 30
            spacing: 16
            Keys.onEscapePressed: app.escapeOverview()
            RowLayout {
                Layout.fillWidth: true
                Column {
                    spacing: 4
                    Text { textFormat: Text.PlainText; font.family: theme.fontFamily; text: "WINDOW ATLAS"; color: theme.accent; font.pixelSize: 12 * theme.fontSize / 12; font.letterSpacing: 3; font.bold: true }
                    Text { textFormat: Text.PlainText; font.family: theme.fontFamily; text: app.displayedWorkspaces.length + (app.displayedWorkspaces.length === 1 ? " desktop" : " desktops") + "  ·  " + app.allWindows.length + (app.allWindows.length === 1 ? " window" : " windows"); color: theme.foreground; font.pixelSize: 20 * theme.fontSize / 12; font.weight: Font.DemiBold }
                }
                Item { Layout.fillWidth: true }
                WindowActionButton {
                    colors: theme
                    Layout.preferredWidth: implicitWidth + 24
                    text: "Arrangement ▾"
                    objectName: "arrangement-button"
                    enabled: !app.busy
                    onClicked: arrangementMenu.open()
                }
                ComboBox {
                    id: desktopCountPicker
                    objectName: "desktop-count"
                    Layout.preferredWidth: 145
                    model: ["Auto desktops", "2 desktops", "4 desktops", "8 desktops"]
                    currentIndex: [0, 2, 4, 8].indexOf(app.desktopCount)
                    font.family: theme.fontFamily
                    font.pixelSize: 13 * theme.fontSize / 12
                    palette.button: theme.raised
                    palette.buttonText: theme.foreground
                    palette.base: theme.background
                    palette.text: theme.foreground
                    palette.window: theme.background
                    palette.windowText: theme.foreground
                    palette.highlight: theme.hover
                    palette.highlightedText: theme.foreground
                    enabled: !app.draggedWindow && !app.busy
                    onActivated: {
                        preferences.desktopCount = [0, 2, 4, 8][currentIndex];
                        search.forceActiveFocus();
                    }
                }
                TextField { font.family: theme.fontFamily;
                    id: search
                    objectName: "overview-search"
                    Layout.preferredWidth: Math.min(330, overlay.width * 0.3)
                    placeholderText: "Find a window…"
                    placeholderTextColor: theme.muted
                    selectionColor: theme.alpha(theme.accent, 0.4)
                    selectedTextColor: theme.foreground
                    color: theme.foreground; font.pixelSize: 14 * theme.fontSize / 12
                    leftPadding: 14; rightPadding: 14; topPadding: 10; bottomPadding: 10
                    background: Rectangle { color: theme.raised; radius: 10; border.color: search.activeFocus ? theme.accent : theme.border }
                    onTextChanged: { app.query = text; app.keyboardIndex = -1; }
                    Keys.onPressed: event => {
                        if (event.modifiers === Qt.NoModifier && app.navigateDesktop(event.key)) event.accepted = true;
                    }
                    Keys.onEscapePressed: app.escapeOverview()
                    Keys.onReturnPressed: app.confirmSelection()
                    Keys.onEnterPressed: app.confirmSelection()
                }
                Button {
                    id: closeButton
                    text: "Esc  ×"
                    hoverEnabled: true
                    leftPadding: 16; rightPadding: 16; topPadding: 11; bottomPadding: 11
                    background: Rectangle {
                        radius: 10
                        color: closeButton.down ? theme.hover : closeButton.hovered ? theme.raised : theme.surface
                        border.color: closeButton.hovered ? theme.accent : theme.border
                        Behavior on color { ColorAnimation { duration: Style.duration(120) } }
                    }
                    contentItem: Text { textFormat: Text.PlainText; font.family: theme.fontFamily;
                        text: closeButton.text
                        color: theme.foreground
                        font.pixelSize: 13 * theme.fontSize / 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: { app.opened = false; app.cancelDrag(); }
                }
            }
            Item {
                id: canvas
                Layout.fillWidth: true
                Layout.fillHeight: true
                readonly property int columns: {
                    const count = app.desktopTiles.length;
                    let best = 1, bestSize = -1, bestEmpty = count;
                    for (let c = 1; c <= count; c++) {
                        const rows = Math.ceil(count / c);
                        const size = Math.floor(Math.min(460, (width - (c - 1) * 16) / c, (height - (rows - 1) * 16) / rows));
                        const empty = c * rows - count;
                        if (size > bestSize || (size === bestSize && empty <= bestEmpty)) {
                            best = c; bestSize = size; bestEmpty = empty;
                        }
                    }
                    return best;
                }
                readonly property int rows: Math.ceil(app.desktopTiles.length / columns)
                readonly property real tileSize: Math.floor(Math.min(460, (width - (columns - 1) * 16) / columns, (height - (rows - 1) * 16) / rows))
                Grid {
                    id: grid
                    anchors.centerIn: parent
                    columns: canvas.columns
                    spacing: 16
                    Repeater {
                        id: desktops
                        model: app.desktopTiles
                        delegate: Rectangle {
                            id: desktop
                            required property int index
                            required property var modelData
                            readonly property bool isNew: modelData === 0 && app.hoverWorkspace < 1
                            readonly property int workspaceId: modelData === 0 ? (app.hoverWorkspace > 0 ? app.hoverWorkspace : app.newWorkspaceId) : modelData
                            property var members: app.windows.filter(w => w === app.pendingWindow ? app.pendingWorkspace === workspaceId : w.workspace && w.workspace.id === workspaceId)
                            readonly property var workspace: Hyprland.workspaces.values.find(w => w.id === workspaceId)
                            readonly property var desktopMonitor: workspace && workspace.monitor ? workspace.monitor : members.length && members[0].monitor ? members[0].monitor : Hyprland.focusedMonitor
                            readonly property var monitorGeometry: desktopMonitor ? desktopMonitor.lastIpcObject : ({width: 1920, height: 1080, scale: 1, x: 0, y: 0})
                            readonly property bool rotated: [1, 3, 5, 7].indexOf(Number(monitorGeometry.transform || 0)) >= 0
                            readonly property real logicalWidth: (rotated ? monitorGeometry.height : monitorGeometry.width) / (monitorGeometry.scale || 1)
                            readonly property real logicalHeight: (rotated ? monitorGeometry.width : monitorGeometry.height) / (monitorGeometry.scale || 1)
                            readonly property bool isTarget: app.dragging && app.dropWorkspace === workspaceId
                            readonly property bool moveSucceeded: app.completedWorkspace === workspaceId && modelData !== 0
                            readonly property bool isKeyboardSelected: app.keyboardIndex === index
                            readonly property bool isHovered: desktopHover.hovered && !app.draggedWindow
                            readonly property bool isCurrent: !isNew && Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === workspaceId
                            opacity: app.query.length && !members.length && !isNew && !isTarget ? 0.38 : 1
                            Behavior on opacity { NumberAnimation { duration: Style.duration(100) } }
                            width: canvas.tileSize; height: width
                            radius: 16
                            color: isTarget ? theme.hover : isCurrent ? theme.selected : isHovered ? theme.raised : theme.surface
                            border.width: isTarget ? 3 : isKeyboardSelected ? 2 : 1
                            border.color: isTarget || isCurrent || isKeyboardSelected ? theme.accent : isHovered ? theme.alpha(theme.accent, 0.85) : theme.border
                            Behavior on color { ColorAnimation { duration: Style.duration(120) } }
                            Behavior on border.color { ColorAnimation { duration: Style.duration(120) } }
                            HoverHandler { id: desktopHover }
                            // Expand only the decoration; pointer and drop geometry stay fixed.
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: desktop.isTarget || desktop.moveSucceeded ? -5 : -3
                                z: -1
                                radius: desktop.radius + 3
                                color: theme.alpha(theme.accent, desktop.isTarget ? 0.18 : 0.08)
                                border.color: theme.alpha(theme.accent, desktop.isTarget ? 0.65 : 0.3)
                                opacity: desktop.isTarget || desktop.moveSucceeded || desktop.isHovered ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: Style.duration(100); easing.type: Easing.OutCubic } }
                            }
                            MouseArea {
                                id: desktopPointer
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                cursorShape: Qt.PointingHandCursor
                                onClicked: mouse => {
                                    if (app.dragging) return;
                                    if (mouse.button === Qt.RightButton) {
                                        const p = mapToItem(overlay.contentItem, mouse.x, mouse.y);
                                        desktopActions.showFor(desktop.workspaceId, p.x, p.y);
                                        return;
                                    }
                                    app.focusWorkspace(desktop.workspaceId);
                                }
                            }
                            Row {
                                x: 14; y: 12; spacing: 7
                                Text { textFormat: Text.PlainText; font.family: theme.fontFamily; width: Math.min(implicitWidth, desktop.width - 95); elide: Text.ElideRight; text: desktop.isNew ? "New desktop" : app.workspaceName(desktop.workspaceId) + (app.workspaceNames[String(desktop.workspaceId)] ? " · " + desktop.workspaceId : ""); color: theme.foreground; font.pixelSize: 14 * theme.fontSize / 12; font.bold: true }
                                Text { textFormat: Text.PlainText; font.family: theme.fontFamily; text: desktop.isCurrent ? "●" : ""; color: theme.accent; font.pixelSize: 12 }
                            }
                            Text { textFormat: Text.PlainText; font.family: theme.fontFamily; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 14; text: desktop.isNew ? "" : app.query.length ? desktop.members.length + " matches" : desktop.members.length; color: theme.muted; font.pixelSize: 12 }
                            // Passive decoration above live captures; pointer areas remain unchanged.
                            Rectangle {
                                objectName: "drop-feedback-" + desktop.workspaceId
                                anchors.fill: parent
                                z: 50000
                                radius: desktop.radius
                                color: theme.alpha(theme.accent, desktop.isTarget ? 0.06 : 0.025)
                                border.width: 2
                                border.color: theme.accent
                                opacity: desktop.isTarget || desktop.moveSucceeded ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: Style.duration(100) } }
                                Rectangle {
                                    anchors.top: parent.top; anchors.topMargin: 40
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: Math.min(parent.width - 16, feedbackText.implicitWidth + 24)
                                    height: feedbackText.implicitHeight + 12
                                    radius: 8
                                    color: theme.alpha(theme.background, 0.97)
                                    border.color: theme.alpha(theme.accent, 0.6)
                                    Text { textFormat: Text.PlainText;
                                        id: feedbackText
                                        anchors.centerIn: parent
                                        width: Math.min(implicitWidth, parent.width - 16)
                                        text: desktop.moveSucceeded ? "✓ Moved to Desktop " + desktop.workspaceId
                                            : app.draggedWindow && app.draggedWindow.workspace && app.draggedWindow.workspace.id === desktop.workspaceId
                                                ? "Already on this desktop" : "Release to move here"
                                        font.family: theme.fontFamily; font.pixelSize: 12 * theme.fontSize / 12
                                        color: theme.accent; elide: Text.ElideRight
                                    }
                                }
                            }
                            Text { textFormat: Text.PlainText; font.family: theme.fontFamily;
                                anchors.centerIn: parent
                                visible: desktop.members.length === 0
                                text: desktop.isTarget ? "Release to move here" : desktop.isNew ? "+" : app.query.length ? "No matches" : "Empty desktop"
                                color: desktop.isTarget ? theme.accent : theme.muted
                                font.pixelSize: desktop.isNew && !desktop.isTarget ? 56 : 16
                            }
                            Item {
                                id: windowArea
                                visible: !desktop.isNew
                                x: 10; y: 42
                                width: parent.width - 20; height: parent.height - 54
                                readonly property real sceneScale: Math.min(width / desktop.logicalWidth, height / desktop.logicalHeight)
                                Rectangle {
                                    id: scene
                                    objectName: "scene-" + desktop.workspaceId
                                    anchors.centerIn: parent
                                    width: desktop.logicalWidth * windowArea.sceneScale
                                    height: desktop.logicalHeight * windowArea.sceneScale
                                    color: theme.background
                                    radius: 3
                                    clip: true
                                    Text { textFormat: Text.PlainText; font.family: theme.fontFamily;
                                        anchors.centerIn: parent
                                        visible: desktop.modelData === 0 && app.hoverWorkspace > 0
                                        text: desktop.isTarget ? "Release to move here" : "New desktop"
                                        color: theme.accent
                                        font.pixelSize: 16 * theme.fontSize / 12
                                    }
                                    Repeater {
                                        id: cards
                                        model: desktop.members
                                        delegate: Rectangle {
                                            id: card
                                            required property var modelData
                                            objectName: "window-" + modelData.address
                                            readonly property var geometry: modelData.lastIpcObject
                                            readonly property var appEntry: app.entryForWindow(modelData)
                                            readonly property string appName: appEntry ? appEntry.name : (geometry.class || "Window")
                                            readonly property string windowTitle: modelData.title || "Untitled window"
                                            readonly property bool selected: app.selectedAddresses.indexOf(modelData.address) >= 0
                                            x: ((geometry.at ? geometry.at[0] : desktop.monitorGeometry.x) - (desktop.monitorGeometry.x || 0)) * windowArea.sceneScale
                                            y: ((geometry.at ? geometry.at[1] : desktop.monitorGeometry.y) - (desktop.monitorGeometry.y || 0)) * windowArea.sceneScale
                                            width: Math.max(1, (geometry.size ? geometry.size[0] : desktop.logicalWidth) * windowArea.sceneScale)
                                            height: Math.max(1, (geometry.size ? geometry.size[1] : desktop.logicalHeight) * windowArea.sceneScale)
                                            z: (geometry.floating ? 10000 : 0) + (geometry.fullscreen ? 20000 : 0) + 1000 - (geometry.focusHistoryID || 0)
                                            radius: 2; color: theme.raised
                                            border.color: selected || pointer.containsMouse ? theme.accent : theme.border
                                            border.width: selected ? 3 : 1
                                            opacity: app.dragging && app.groupFor(app.draggedWindow).indexOf(modelData) >= 0 ? 0.35 : 1
                                            ScreencopyView {
                                                id: preview
                                                anchors.centerIn: parent
                                                captureSource: app.opened ? card.modelData.wayland : null
                                                live: app.opened
                                                paintCursor: false
                                                constraintSize: Qt.size(Math.max(1, card.width - 2), Math.max(1, card.height - 2))
                                                width: implicitWidth; height: implicitHeight
                                            }
                                            Text { textFormat: Text.PlainText; font.family: theme.fontFamily;
                                                anchors.centerIn: parent; visible: !preview.hasContent
                                                text: card.modelData.lastIpcObject.class || "Window"; color: theme.muted; font.pixelSize: 10 * theme.fontSize / 12
                                                width: parent.width - 6; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                                            }
                                            Rectangle {
                                                id: windowLabel
                                                objectName: "label-" + card.modelData.address
                                                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                                                height: Math.min(36, parent.height)
                                                visible: card.height >= 24 && !app.dragging
                                                clip: true
                                                color: theme.alpha(theme.background, 0.94)
                                                Image {
                                                    id: appImage
                                                    objectName: "icon-" + card.modelData.address
                                                    anchors.left: parent.left; anchors.leftMargin: 5
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: 20; height: 20
                                                    source: app.appIcon(card.appEntry)
                                                    sourceSize: Qt.size(40, 40)
                                                    fillMode: Image.PreserveAspectFit
                                                }
                                                Text { textFormat: Text.PlainText;
                                                    anchors.centerIn: appImage
                                                    visible: appImage.status !== Image.Ready
                                                    text: card.appName.charAt(0).toUpperCase()
                                                    color: theme.accent; font.family: theme.fontFamily; font.bold: true; font.pixelSize: 14
                                                }
                                                Column {
                                                    anchors.left: appImage.right; anchors.leftMargin: 6
                                                    anchors.right: parent.right; anchors.rightMargin: 5
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    visible: card.width >= 90
                                                    Text { textFormat: Text.PlainText;
                                                        width: parent.width; text: card.appName
                                                        font.family: theme.fontFamily; font.bold: true; font.pixelSize: 10 * theme.fontSize / 12
                                                        color: theme.muted; elide: Text.ElideRight
                                                    }
                                                    Text { textFormat: Text.PlainText;
                                                        width: parent.width; text: card.windowTitle
                                                        font.family: theme.fontFamily; font.pixelSize: 11 * theme.fontSize / 12
                                                        color: theme.foreground; elide: Text.ElideRight
                                                    }
                                                }
                                            }
                                            ToolTip.visible: pointer.containsMouse && !app.draggedWindow
                                                && !windowActions.visible
                                            ToolTip.delay: 600
                                            ToolTip.text: card.appName + "\n" + card.windowTitle
                                            Rectangle {
                                                anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 5
                                                width: 23; height: 23; radius: 6
                                                visible: card.selected
                                                color: theme.accent
                                                Text { textFormat: Text.PlainText; anchors.centerIn: parent; text: "✓"; color: theme.background; font.bold: true }
                                            }
                                            MouseArea {
                                                id: pointer
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                preventStealing: true
                                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                                property bool selectingWithControl: false
                                                cursorShape: app.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                                onPressed: mouse => {
                                                    if (mouse.button !== Qt.LeftButton) return;
                                                    selectingWithControl = (mouse.modifiers & Qt.ControlModifier) !== 0;
                                                    if (selectingWithControl) return;
                                                    const p = mapToItem(overlay.contentItem, mouse.x, mouse.y);
                                                    app.beginDrag(card.modelData, p.x, p.y);
                                                }
                                                onPositionChanged: mouse => {
                                                    if (!pressed) return;
                                                    const p = mapToItem(overlay.contentItem, mouse.x, mouse.y);
                                                    app.updateDrag(p.x, p.y);
                                                }
                                                onReleased: mouse => {
                                                    const p = mapToItem(overlay.contentItem, mouse.x, mouse.y);
                                                    if (mouse.button === Qt.RightButton) {
                                                        app.cancelDrag();
                                                        windowActions.showFor(card.modelData, p.x, p.y);
                                                        return;
                                                    }
                                                    if (selectingWithControl) { app.toggleSelected(card.modelData); selectingWithControl = false; return; }
                                                    app.finishDrag(p.x, p.y);
                                                }
                                                onCanceled: app.cancelDrag()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.minimumHeight: 40
                Layout.maximumHeight: 40
                Text { textFormat: Text.PlainText;
                    visible: app.query.length > 0
                    text: app.windows.length + (app.windows.length === 1 ? " matching window" : " matching windows")
                    color: theme.accent; font.family: theme.fontFamily; font.pixelSize: 13
                }
                WindowActionButton {
                    colors: theme
                    objectName: "clear-selection"
                    visible: app.selectedAddresses.length > 0
                    text: app.selectedAddresses.length + " selected · Clear"
                    Layout.preferredWidth: implicitWidth + 20
                    onClicked: app.selectedAddresses = []
                }
                Text { textFormat: Text.PlainText; font.family: theme.fontFamily; Layout.fillWidth: true; text: app.notice; color: theme.muted; font.pixelSize: 13 * theme.fontSize / 12; elide: Text.ElideRight }
                WindowActionButton {
                    colors: theme
                    objectName: "undo-move"
                    visible: app.undoMoves.length > 0
                    enabled: !app.busy
                    text: "Undo move"
                    Layout.preferredWidth: implicitWidth + 20
                    onClicked: app.undoLastMove()
                }
                Text { textFormat: Text.PlainText; font.family: theme.fontFamily; text: "Arrows + Enter · Type to search · Right-click for actions · Esc to close"; color: theme.muted; font.pixelSize: 12 }
            }
        }
        Rectangle {
            id: ghost
            visible: app.dragging && app.draggedWindow !== null
            x: app.pointerPoint.x - width / 2
            y: app.pointerPoint.y - height / 2
            width: 220; height: 155
            z: 100
            radius: 12; color: theme.alpha(theme.raised, 0.97); border.width: 2; border.color: theme.accent
            ScreencopyView {
                anchors.centerIn: parent
                captureSource: ghost.visible && app.draggedWindow ? app.draggedWindow.wayland : null
                live: ghost.visible
                paintCursor: false
                constraintSize: Qt.size(204, 139)
                width: implicitWidth; height: implicitHeight
            }
            Rectangle {
                anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 6
                visible: app.draggedWindow !== null && app.groupFor(app.draggedWindow).length > 1
                width: 28; height: 28; radius: 14; color: theme.accent
                Text { textFormat: Text.PlainText; anchors.centerIn: parent; text: app.draggedWindow ? app.groupFor(app.draggedWindow).length : ""; color: theme.background; font.bold: true }
            }
        }
        Popup {
            id: windowActions
            objectName: "window-actions"
            parent: overlay.contentItem
            property var targetWindow: null
            readonly property bool validWindow: targetWindow !== null && app.allWindows.indexOf(targetWindow) >= 0
            width: Math.min(280, overlay.width - 24)
            height: Math.min(actionList.implicitHeight + padding * 2, overlay.height - 24)
            padding: 8
            modal: true
            dim: false
            focus: true
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
            function showFor(w, px, py) {
                targetWindow = w;
                x = Math.max(12, Math.min(px, overlay.width - width - 12));
                y = Math.max(12, Math.min(py, overlay.height - height - 12));
                open();
            }
            onClosed: { targetWindow = null; if (app.opened) search.forceActiveFocus(); }
            background: Rectangle { radius: 10; color: theme.background; border.color: theme.border }
            contentItem: ScrollView {
                clip: true
                contentWidth: availableWidth
                Column {
                    id: actionList
                    width: parent.width
                    spacing: 2
                    Text { textFormat: Text.PlainText;
                        width: parent.width; padding: 10
                        text: windowActions.targetWindow ? windowActions.targetWindow.title || "Window" : "Window"
                        font.family: theme.fontFamily; font.pixelSize: 12 * theme.fontSize / 12
                        color: theme.muted; elide: Text.ElideRight
                    }
                    WindowActionButton {
                        colors: theme
                        objectName: "action-fullscreen"
                        text: windowActions.targetWindow && windowActions.targetWindow.wayland && windowActions.targetWindow.wayland.fullscreen ? "Exit fullscreen" : "Fullscreen"
                        enabled: windowActions.validWindow && !!windowActions.targetWindow.wayland
                        onClicked: {
                            const w = windowActions.targetWindow;
                            windowActions.close();
                            if (w && w.wayland) w.wayland.fullscreen = !w.wayland.fullscreen;
                        }
                    }
                    Text { textFormat: Text.PlainText;
                        text: windowActions.targetWindow && app.groupFor(windowActions.targetWindow).length > 1 ? "Move " + app.groupFor(windowActions.targetWindow).length + " selected windows" : "Move to desktop"; padding: 10; color: theme.muted
                        font.family: theme.fontFamily; font.pixelSize: 11 * theme.fontSize / 12
                    }
                    Repeater {
                        model: app.desktopTiles
                        WindowActionButton {
                            colors: theme
                            required property var modelData
                            readonly property int destination: modelData === 0 ? app.newWorkspaceId : modelData
                            objectName: modelData === 0 ? "action-move-new" : "action-move-" + destination
                            text: modelData === 0 ? "+ New desktop" : app.workspaceName(destination)
                            enabled: windowActions.validWindow && !app.busy
                                && app.groupFor(windowActions.targetWindow).some(w => !w.workspace || w.workspace.id !== destination)
                            onClicked: {
                                const w = windowActions.targetWindow;
                                const id = destination;
                                windowActions.close();
                                app.moveWindows(app.groupFor(w), id);
                            }
                        }
                    }
                    Rectangle { width: parent.width; height: 1; color: theme.border }
                    WindowActionButton {
                        colors: theme
                        objectName: "action-close"
                        text: "Close window"
                        enabled: windowActions.validWindow && !!windowActions.targetWindow.wayland
                        onClicked: {
                            const w = windowActions.targetWindow;
                            windowActions.close();
                            if (w && w.wayland) w.wayland.close();
                        }
                    }
                }
            }
        }
        Popup {
            id: desktopActions
            objectName: "desktop-actions"
            parent: overlay.contentItem
            property int workspaceId: 1
            width: 280
            height: desktopActionList.implicitHeight + padding * 2
            padding: 8; modal: true; dim: false; focus: true
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
            function showFor(id, px, py) {
                workspaceId = id;
                x = Math.max(12, Math.min(px, overlay.width - width - 12));
                y = Math.max(12, Math.min(py, overlay.height - height - 12));
                open();
            }
            onClosed: if (app.opened) search.forceActiveFocus()
            background: Rectangle { color: theme.background; radius: 10; border.color: theme.border }
            contentItem: Column {
                id: desktopActionList
                spacing: 4
                Text { textFormat: Text.PlainText; width: parent.width; padding: 10; text: app.workspaceName(desktopActions.workspaceId); color: theme.muted; font.family: theme.fontFamily; elide: Text.ElideRight }
                WindowActionButton {
                    colors: theme; text: "Rename desktop…"; objectName: "action-rename"
                    enabled: !app.busy
                    onClicked: {
                        renameDialog.workspaceId = desktopActions.workspaceId;
                        desktopActions.close();
                        renameDialog.open();
                    }
                }
                WindowActionButton {
                    colors: theme; text: "Open an app here…"; objectName: "action-launch"
                    enabled: !app.busy
                    onClicked: {
                        launcher.workspaceId = desktopActions.workspaceId;
                        desktopActions.close();
                        launcher.open();
                    }
                }
            }
        }
        Dialog {
            id: renameDialog
            objectName: "rename-desktop"
            parent: overlay.contentItem
            property int workspaceId: 1
            x: (overlay.width - width) / 2; y: (overlay.height - height) / 2
            width: 380
            title: "Name desktop " + workspaceId
            modal: true; focus: true
            standardButtons: Dialog.Save | Dialog.Cancel
            palette.window: theme.background; palette.windowText: theme.foreground
            palette.button: theme.raised; palette.buttonText: theme.foreground
            palette.base: theme.surface; palette.text: theme.foreground
            onOpened: {
                renameInput.text = app.workspaceNames[String(workspaceId)] || "";
                renameInput.forceActiveFocus(); renameInput.selectAll();
            }
            onAccepted: app.renameWorkspace(workspaceId, renameInput.text)
            onClosed: if (app.opened) search.forceActiveFocus()
            contentItem: TextField {
                id: renameInput
                objectName: "rename-input"
                placeholderText: "Code, Browser, Chat…"
                maximumLength: 40
                color: theme.foreground
                font.family: theme.fontFamily
                Keys.onReturnPressed: renameDialog.accept()
                Keys.onEnterPressed: renameDialog.accept()
            }
        }
        Popup {
            id: launcher
            objectName: "desktop-launcher"
            parent: overlay.contentItem
            property int workspaceId: 1
            width: Math.min(480, overlay.width - 24)
            height: Math.min(580, overlay.height - 100)
            x: (overlay.width - width) / 2; y: (overlay.height - height) / 2
            padding: 16; modal: true; dim: false; focus: true
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
            onOpened: { launchSearch.clear(); launchSearch.forceActiveFocus(); }
            onClosed: if (app.opened) search.forceActiveFocus()
            background: Rectangle { color: theme.background; radius: 12; border.color: theme.border }
            contentItem: ColumnLayout {
                spacing: 12
                Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: "Open on " + app.workspaceName(launcher.workspaceId); color: theme.foreground; font.family: theme.fontFamily; font.pixelSize: 18; elide: Text.ElideRight }
                TextField {
                    id: launchSearch
                    objectName: "launch-search"
                    Layout.fillWidth: true
                    placeholderText: "Find an installed app…"
                    color: theme.foreground; font.family: theme.fontFamily
                    background: Rectangle { color: theme.raised; radius: 6; border.color: theme.border }
                    onTextChanged: launchList.currentIndex = 0
                    Keys.onDownPressed: launchList.currentIndex = Math.min(launchList.count - 1, launchList.currentIndex + 1)
                    Keys.onUpPressed: launchList.currentIndex = Math.max(0, launchList.currentIndex - 1)
                    Keys.onReturnPressed: {
                        const entry = launchList.model[launchList.currentIndex];
                        if (entry) { const id = launcher.workspaceId; launcher.close(); app.launchOnWorkspace(entry, id); }
                    }
                }
                ListView {
                    id: launchList
                    objectName: "launch-list"
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    model: DesktopEntries.applications.values.filter(entry => !entry.noDisplay && entry.name.toLowerCase().includes(launchSearch.text.toLowerCase())).sort((a, b) => a.name.localeCompare(b.name))
                    currentIndex: 0
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: WindowActionButton {
                        required property var modelData
                        required property int index
                        colors: theme
                        width: launchList.width
                        text: modelData.name
                        highlighted: index === launchList.currentIndex
                        onClicked: { const entry = modelData; const id = launcher.workspaceId; launcher.close(); app.launchOnWorkspace(entry, id); }
                    }
                    ScrollBar.vertical: ScrollBar {}
                }
                Text { textFormat: Text.PlainText; visible: launchList.count === 0; text: "No matching installed apps"; color: theme.muted; font.family: theme.fontFamily }
            }
        }
        Popup {
            id: arrangementMenu
            objectName: "arrangement-menu"
            parent: overlay.contentItem
            width: 380; height: arrangementList.implicitHeight + padding * 2
            x: (overlay.width - width) / 2; y: 90
            padding: 12; modal: true; dim: false; focus: true
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
            onClosed: if (app.opened) search.forceActiveFocus()
            background: Rectangle { color: theme.background; radius: 10; border.color: theme.border }
            contentItem: Column {
                id: arrangementList
                spacing: 6
                Text { textFormat: Text.PlainText; width: parent.width; padding: 8; text: app.savedArrangement.length ? app.savedArrangement.length + " saved window groups" : "No arrangement saved yet"; color: theme.foreground; font.family: theme.fontFamily }
                Text { textFormat: Text.PlainText; width: parent.width; padding: 8; text: "Remember which apps belong on each desktop. App documents and terminal sessions are not saved."; wrapMode: Text.WordWrap; color: theme.muted; font.family: theme.fontFamily }
                WindowActionButton { colors: theme; text: "Save current arrangement"; objectName: "save-arrangement"; enabled: !app.busy; onClicked: { app.saveArrangement(); arrangementMenu.close(); } }
                WindowActionButton { colors: theme; text: "Restore open windows"; objectName: "restore-arrangement"; enabled: !app.busy && app.savedArrangement.length > 0; onClicked: { arrangementMenu.close(); app.restoreArrangement(false); } }
                WindowActionButton { colors: theme; text: "Restore and open missing apps"; objectName: "restore-and-launch"; enabled: !app.busy && app.savedArrangement.length > 0; onClicked: { arrangementMenu.close(); app.restoreArrangement(true); } }
            }
        }

    }
}
