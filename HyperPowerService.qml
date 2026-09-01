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
  property var pendingBurst: null

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
      toplevel && toplevel.appId
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

  function screenForPoint(x, y) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (x >= screen.x && x < screen.x + screen.width && y >= screen.y && y < screen.y + screen.height)
        return screen
    }
    return screens.length > 0 ? screens[0] : null
  }

  function focusedTarget(requireTerminal) {
    var top = Hyprland.activeToplevel
    var ipc = top && top.lastIpcObject ? top.lastIpcObject : null
    if (!top || !ipc) return null
    if (requireTerminal && !isSupportedTerminal(top, ipc)) return null
    var at = Array.isArray(ipc.at) ? ipc.at : [0, 0]
    var size = Array.isArray(ipc.size) ? ipc.size : [0, 0]
    if (size.length < 2 || Number(size[0]) <= 0 || Number(size[1]) <= 0) return null
    var left = Number(at[0])
    var topY = Number(at[1])
    var width = Number(size[0])
    var height = Number(size[1])
    var x = left + width * settings.originXRatio
    var y = topY + height - settings.originBottomOffset
    var screen = screenForPoint(left + width / 2, topY + height / 2)
    if (!screen) return null
    return {
      screenName: String(screen.name),
      x: x,
      y: y,
      windowX: left,
      windowY: topY,
      windowWidth: width,
      windowHeight: height,
      approximate: true
    }
  }

  function requestBurst(source, requireTerminal, overridePosition, retryCount) {
    if (!effectEnabled || !settings.particlesEnabled) return "disabled"
    var target = focusedTarget(requireTerminal)
    if (!target) {
      var top = Hyprland.activeToplevel
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
    acceptedBursts += 1
    burstRequested(target)
    return "ok"
  }

  function handleSocketLine(line) {
    var token = String(line || "").trim()
    if (token !== "burst") return
    if (settings.inputMode === "socket" || settings.inputMode === "both")
      requestBurst("shell-integration", true, null)
  }

  function handleActivityChanged() {
    if (activityMonitor.isIdle) return
    if (settings.inputMode !== "activity" && settings.inputMode !== "both") return
    requestBurst("wayland-activity", true, null)
  }

  function refreshForHyprlandEvent(event) {
    var name = String(event && event.name ? event.name : "")
    if (name.indexOf("activewindow") === 0 || name.indexOf("openwindow") === 0
        || name.indexOf("movewindow") === 0 || name === "focusedmon") {
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
    function status(): string {
      return JSON.stringify({
        enabled: root.effectEnabled,
        socket: root.socketPath,
        acceptedBursts: root.acceptedBursts,
        settings: root.settings
      })
    }
    function ping(): string { return "ok" }
  }

  Component.onCompleted: {
    reloadSettings()
    Hyprland.refreshMonitors()
    Hyprland.refreshToplevels()
    socketCleanup.running = true
  }
}
