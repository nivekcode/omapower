pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

Item {
  id: root

  width: 0
  height: 0
  visible: false

  property var shell: null
  property var manifest: null
  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "io.github.nivekcode.omapower"
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string socketPath: runtimeDir + "/omapower.sock"
  property var settings: model.sanitized({})
  property bool effectEnabled: true
  property bool socketReady: false
  property int acceptedBursts: 0
  property int settingsReloadAttempts: 0
  property var pendingBurst: null
  property bool typedBurstPending: false
  property string typedBurstSource: "terminal-input"
  property var caretPositions: ({})
  property var lastBurstTarget: null

  signal burstRequested(var event)
  signal settingsReloaded()

  HyperPower { id: model }

  function pluginEntry() {
    var config = shell && shell.shellConfig ? shell.shellConfig : null
    if (!config || !Array.isArray(config.plugins)) return null
    for (var i = 0; i < config.plugins.length; i++) {
      var entry = config.plugins[i]
      if (entry && String(entry.id || "") === pluginId) return entry
    }
    return null
  }

  function reloadSettings() {
    settings = model.sanitized(pluginEntry() || {})
    effectEnabled = settings.particlesEnabled
    settingsReloaded()
    return "ok"
  }

  function terminalIdentity(toplevel, ipc) {
    var values = [
      ipc && ipc.class,
      ipc && ipc.initialClass,
      toplevel && toplevel.appId,
      toplevel && toplevel.wayland && toplevel.wayland.appId
    ]
    return values.map(function(value) { return String(value || "").toLowerCase() }).join("\n")
  }

  function isSupportedTerminal(toplevel, ipc) {
    var identity = terminalIdentity(toplevel, ipc)
    var identifiers = settings.terminalIdentifiers || []
    for (var i = 0; i < identifiers.length; i++) {
      if (identity.indexOf(String(identifiers[i]).toLowerCase()) >= 0) return true
    }
    return false
  }

  function activeToplevel() {
    if (Hyprland.activeToplevel) return Hyprland.activeToplevel
    var values = Hyprland.toplevels && Hyprland.toplevels.values ? Hyprland.toplevels.values : []
    var best = null
    var bestHistory = 2147483647
    for (var i = 0; i < values.length; i++) {
      var candidate = values[i]
      var ipc = candidate && candidate.lastIpcObject ? candidate.lastIpcObject : null
      if (!ipc) continue
      if (ipc.acceptsInput === true) return candidate
      var history = Number(ipc.focusHistoryID)
      if (isFinite(history) && history >= 0 && history < bestHistory) {
        best = candidate
        bestHistory = history
      }
    }
    return best
  }

  function screenForPoint(x, y) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (x >= screen.x && x < screen.x + screen.width && y >= screen.y && y < screen.y + screen.height)
        return screen
    }
    return screens.length > 0 ? screens[0] : null
  }

  function windowKey(toplevel, ipc) {
    return String((toplevel && toplevel.address) || (ipc && ipc.address) || "").toLowerCase()
  }

  function caretFor(toplevel, ipc) {
    if (!settings.caretTrackingEnabled) return null
    var key = windowKey(toplevel, ipc)
    return key ? caretPositions[key] || null : null
  }

  function setCaret(rowValue, columnValue, rowsValue, columnsValue, anchorValue, cellHeightValue, cellWidthValue) {
    var top = activeToplevel()
    var ipc = top && top.lastIpcObject ? top.lastIpcObject : null
    if (!top || !ipc || !isSupportedTerminal(top, ipc)) return "not-terminal"
    var row = Math.max(1, Math.round(Number(rowValue)))
    var column = Math.max(1, Math.round(Number(columnValue)))
    var rows = Math.max(1, Math.round(Number(rowsValue)))
    var columns = Math.max(1, Math.round(Number(columnsValue)))
    var cellHeight = Math.max(0, Number(cellHeightValue || 0))
    var cellWidth = Math.max(0, Number(cellWidthValue || 0))
    if (!isFinite(row) || !isFinite(column) || !isFinite(rows) || !isFinite(columns)) return "invalid"
    if (!isFinite(cellHeight)) cellHeight = 0
    if (!isFinite(cellWidth)) cellWidth = 0
    var key = windowKey(top, ipc)
    if (!key) return "no-window"
    var next = ({})
    for (var existing in caretPositions) next[existing] = caretPositions[existing]
    next[key] = {
      row: Math.min(row, rows),
      column: Math.min(column, columns),
      rows: rows,
      columns: columns,
      anchor: String(anchorValue || "cursor"),
      cellHeight: cellHeight,
      cellWidth: cellWidth,
      updatedAt: Date.now()
    }
    caretPositions = next
    return "ok"
  }

  function advanceFocusedCaret() {
    if (!settings.caretTrackingEnabled) return
    var top = activeToplevel()
    var ipc = top && top.lastIpcObject ? top.lastIpcObject : null
    var key = windowKey(top, ipc)
    var current = key ? caretPositions[key] : null
    if (!current) return
    var nextColumn = current.column + 1
    var nextRow = current.row
    if (nextColumn > current.columns) {
      nextColumn = 1
      nextRow = Math.min(current.rows, nextRow + 1)
    }
    var next = ({})
    for (var existing in caretPositions) next[existing] = caretPositions[existing]
    next[key] = {
      row: nextRow,
      column: nextColumn,
      rows: current.rows,
      columns: current.columns,
      anchor: current.anchor,
      cellHeight: current.cellHeight,
      cellWidth: current.cellWidth,
      updatedAt: Date.now()
    }
    caretPositions = next
  }

  function queueTypedBurst(source) {
    typedBurstSource = String(source || "terminal-input")
    typedBurstPending = true
    typedBurstDelay.restart()
  }

  function focusedTarget(requireTerminal) {
    var top = activeToplevel()
    var ipc = top && top.lastIpcObject ? top.lastIpcObject : null
    if (!top || !ipc) return null
    if (requireTerminal && !isSupportedTerminal(top, ipc)) return null
    var at = ipc.at
    var size = ipc.size
    if (!at || at.length < 2 || !size || size.length < 2
        || Number(size[0]) <= 0 || Number(size[1]) <= 0) return null
    var left = Number(at[0])
    var topY = Number(at[1])
    var width = Number(size[0])
    var height = Number(size[1])
    var screen = screenForPoint(left + width / 2, topY + height / 2)
    if (!screen) return null
    var monitor = top.monitor || Hyprland.monitorFor(screen)
    var outputScale = Number(monitor && monitor.scale ? monitor.scale : 0)
    if (!isFinite(outputScale) || outputScale <= 0) outputScale = 0
    var caret = caretFor(top, ipc)
    var x = left + width * settings.originXRatio
    var y = topY + height - settings.originBottomOffset
    var positionMode = "window-approximation"
    var cursorMetrics = null
    if (caret) {
      var availableWidth = Math.max(1, width - settings.terminalPaddingX * 2)
      var availableHeight = Math.max(1, height - settings.terminalPaddingY * 2)
      var cellWidth = availableWidth / caret.columns
      var cellHeight = availableHeight / caret.rows
      var metricScale = 0
      if (caret.cellWidth > 0 && caret.cellHeight > 0) {
        metricScale = outputScale > 0
          ? outputScale
          : Math.max(1, caret.cellWidth * caret.columns / availableWidth)
        cellWidth = caret.cellWidth / metricScale
        cellHeight = caret.cellHeight / metricScale
      }
      var gridWidth = cellWidth * caret.columns
      var gridHeight = cellHeight * caret.rows
      var gridPaddingX = Math.min(settings.terminalPaddingX, Math.max(0, width - gridWidth))
      var gridPaddingY = Math.min(settings.terminalPaddingY, Math.max(0, height - gridHeight))
      // Hyperpower emits from cursorFrame.x. Match that leading edge instead of
      // shifting half a cell into the block cursor.
      var columnOffset = caret.anchor === "character" ? -1 : 0
      x = left + gridPaddingX + (caret.column - 1 + columnOffset) * cellWidth
      y = topY + gridPaddingY + (caret.row - 0.5) * cellHeight
      positionMode = metricScale > 0 ? "terminal-metrics" : "terminal-grid"
      cursorMetrics = {
        scale: metricScale,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        paddingX: gridPaddingX,
        paddingY: gridPaddingY,
        cursorLeft: left + gridPaddingX + (caret.column - 1) * cellWidth,
        cursorTop: topY + gridPaddingY + (caret.row - 1) * cellHeight
      }
    }
    return {
      screenName: String(screen.name),
      x: x,
      y: y,
      windowX: left,
      windowY: topY,
      windowWidth: width,
      windowHeight: height,
      approximate: positionMode !== "terminal-metrics",
      positionMode: positionMode,
      cursorMetrics: cursorMetrics
    }
  }

  function requestBurst(source, requireTerminal, overridePosition, retryCount) {
    if (!effectEnabled || !settings.particlesEnabled) return "disabled"
    var target = focusedTarget(requireTerminal)
    if (!target) {
      var top = activeToplevel()
      var attempts = Number(retryCount || 0)
      if (top && !top.lastIpcObject && attempts < 2) {
        pendingBurst = {
          source: source,
          requireTerminal: requireTerminal,
          overridePosition: overridePosition,
          retryCount: attempts + 1
        }
        Hyprland.refreshToplevels()
        geometryRetry.restart()
        return "refreshing"
      }
      return requireTerminal ? "not-terminal" : "no-window"
    }
    if (overridePosition && isFinite(Number(overridePosition.x)) && isFinite(Number(overridePosition.y))) {
      target.x = Number(overridePosition.x)
      target.y = Number(overridePosition.y)
      target.approximate = false
    }
    target.source = String(source || "unknown")
    target.settings = settings
    lastBurstTarget = {
      source: target.source,
      screenName: target.screenName,
      x: target.x,
      y: target.y,
      windowX: target.windowX,
      windowY: target.windowY,
      windowWidth: target.windowWidth,
      windowHeight: target.windowHeight,
      positionMode: target.positionMode,
      cursorMetrics: target.cursorMetrics
    }
    acceptedBursts += 1
    burstRequested(target)
    return "ok"
  }

  function handleSocketLine(line) {
    var token = String(line || "").trim()
    var fields = token.split(/\s+/)
    if (fields[0] === "caret" && fields.length === 5) {
      setCaret(fields[1], fields[2], fields[3], fields[4], "cursor")
      return
    }
    if (fields[0] === "type" && (fields.length === 5 || fields.length === 7)) {
      if (settings.inputMode !== "socket" && settings.inputMode !== "both") return
      if (setCaret(fields[1], fields[2], fields[3], fields[4], "cursor", fields[5], fields[6]) === "ok") {
        queueTypedBurst("bash-readline")
      }
      return
    }
    if (token === "burst" && (settings.inputMode === "socket" || settings.inputMode === "both")) {
      advanceFocusedCaret()
      queueTypedBurst("shell-integration")
    }
  }

  function handleActivityChanged() {
    if (activityMonitor.isIdle) return
    if (settings.inputMode !== "activity" && settings.inputMode !== "both") return
    advanceFocusedCaret()
    queueTypedBurst("wayland-activity")
  }

  function refreshForHyprlandEvent(event) {
    var name = String(event && event.name ? event.name : "")
    if (name.indexOf("activewindow") === 0 || name.indexOf("openwindow") === 0
        || name.indexOf("movewindow") === 0 || name.indexOf("resizewindow") === 0
        || name === "focusedmon") {
      Hyprland.refreshToplevels()
      if (name === "focusedmon") Hyprland.refreshMonitors()
    }
  }

  function setEnabled(enabled) {
    effectEnabled = enabled
    var next = ({})
    var current = settings
    for (var key in current) next[key] = current[key]
    next.particlesEnabled = enabled
    settings = model.sanitized(next)
    persistSettings()
    return enabled ? "enabled" : "disabled"
  }

  function persistSettings() {
    if (!shell || typeof shell.updateEntryInline !== "function") return false
    return shell.updateEntryInline(pluginId, settings)
  }

  function setSetting(key, rawValue) {
    var allowed = model.defaults
    if (allowed[key] === undefined) return "unknown-setting"
    var value = rawValue
    if (key === "terminalIdentifiers") {
      try { value = JSON.parse(rawValue) } catch (e) { value = String(rawValue).split(",") }
    } else if (typeof allowed[key] === "boolean") {
      value = String(rawValue).toLowerCase() === "true" || String(rawValue) === "1"
    } else if (typeof allowed[key] === "number") {
      value = Number(rawValue)
    }
    var next = ({})
    for (var currentKey in settings) next[currentKey] = settings[currentKey]
    next[key] = value
    settings = model.sanitized(next)
    effectEnabled = settings.particlesEnabled
    persistSettings()
    return JSON.stringify(settings[key])
  }

  function diagnostics() {
    var top = activeToplevel()
    var ipc = top && top.lastIpcObject ? top.lastIpcObject : null
    var screens = []
    for (var i = 0; i < Quickshell.screens.length; i++) {
      var screen = Quickshell.screens[i]
      screens.push({ name: String(screen.name), x: screen.x, y: screen.y, width: screen.width, height: screen.height })
    }
    return {
      hasActiveToplevel: top !== null,
      appId: String((ipc && (ipc.class || ipc.initialClass)) || (top && top.appId) || ""),
      hasIpcGeometry: ipc !== null && ipc.at !== undefined && ipc.size !== undefined,
      at: ipc && ipc.at ? [Number(ipc.at[0]), Number(ipc.at[1])] : [],
      size: ipc && ipc.size ? [Number(ipc.size[0]), Number(ipc.size[1])] : [],
      screens: screens,
      caret: caretFor(top, ipc),
      target: focusedTarget(false),
      lastBurstTarget: lastBurstTarget
    }
  }

  Connections {
    target: root.shell
    ignoreUnknownSignals: true
    function onShellConfigChanged() { root.reloadSettings() }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { root.refreshForHyprlandEvent(event) }
  }

  Timer {
    id: geometryRetry
    interval: 60
    repeat: false
    onTriggered: {
      var pending = root.pendingBurst
      root.pendingBurst = null
      if (pending)
        root.requestBurst(pending.source, pending.requireTerminal, pending.overridePosition, pending.retryCount)
    }
  }

  // Wayland reports input before Foot paints it. Wait for the next terminal
  // frame and coalesce only keys that arrive inside that redraw interval.
  Timer {
    id: typedBurstDelay
    interval: 25
    repeat: false
    onTriggered: {
      if (!root.typedBurstPending) return
      root.typedBurstPending = false
      root.requestBurst(root.typedBurstSource, true, null)
    }
  }

  Timer {
    id: settingsRetry
    interval: 200
    repeat: true
    onTriggered: {
      root.reloadSettings()
      root.settingsReloadAttempts += 1
      if (root.pluginEntry() || root.settingsReloadAttempts >= 10) stop()
    }
  }

  SocketServer {
    id: inputServer
    path: root.socketPath
    active: root.socketReady
    handler: Socket {
      parser: SplitParser {
        splitMarker: "\n"
        onRead: function(line) { root.handleSocketLine(line) }
      }
    }
  }

  IdleMonitor {
    id: activityMonitor
    enabled: root.effectEnabled && (root.settings.inputMode === "activity" || root.settings.inputMode === "both")
    timeout: root.settings.activityResetDelay / 1000
    respectInhibitors: false
    onIsIdleChanged: root.handleActivityChanged()
  }

  Process {
    id: socketCleanup
    command: ["rm", "-f", root.socketPath]
    onExited: root.socketReady = true
  }

  IpcHandler {
    target: "omapower"

    function burst(): string { return root.requestBurst("ipc", false, null) }
    function enable(): string { return root.setEnabled(true) }
    function disable(): string { return root.setEnabled(false) }
    function toggle(): string { return root.setEnabled(!root.effectEnabled) }
    function reloadSettings(): string { return root.reloadSettings() }
    function set(key: string, value: string): string { return root.setSetting(key, value) }
    function caret(row: string, column: string, rows: string, columns: string): string {
      return root.setCaret(row, column, rows, columns)
    }
    function status(): string {
      return JSON.stringify({
        enabled: root.effectEnabled,
        socket: root.socketPath,
        acceptedBursts: root.acceptedBursts,
        lastBurstTarget: root.lastBurstTarget,
        settings: root.settings
      })
    }
    function diagnostics(): string { return JSON.stringify(root.diagnostics()) }
    function ping(): string { return "ok" }
  }

  Component.onCompleted: {
    reloadSettings()
    Hyprland.refreshMonitors()
    Hyprland.refreshToplevels()
    socketCleanup.running = true
    settingsRetry.start()
  }
}
