pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  property var service: null
  property bool opened: true
  property int activeParticles: 0
  property int burstSerial: 0

  function open(payloadJson) {
    opened = true
    if (service) service.requestBurst("summon", false, null)
  }

  function close() { opened = false }
  function burst() { return service ? service.requestBurst("overlay", false, null) : "no-service" }
  function enable() { opened = true; return service ? service.setEnabled(true) : "no-service" }
  function disable() { return service ? service.setEnabled(false) : "no-service" }
  function toggle() { return service ? service.setEnabled(!service.effectEnabled) : "no-service" }
  function reloadSettings() { return service ? service.reloadSettings() : "no-service" }

  function colorFor(mode, customColor) {
    if (mode === "rainbow") return Qt.hsla(Math.random(), 0.82, 0.64, 1)
    if (mode === "fixed") return customColor
    return Color.accent
  }

  function emitBurst(layer, event) {
    if (!opened || !event || !event.settings || String(layer.screen.name) !== String(event.screenName)) return
    var settings = event.settings
    var available = Math.max(0, settings.maximumActiveParticles - activeParticles)
    var localX = event.x - layer.screen.x
    var localY = event.y - layer.screen.y
    var count = layer.particleField.addBurst(localX, localY, settings, available, Color.accent)
    if (count <= 0) return
    activeParticles += count
    if (settings.shakeEnabled && settings.shakeStrength > 0) layer.shake(settings)
    burstSerial += 1
  }

  Variants {
    id: surfaceRepeater
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData
      readonly property var screenInfo: modelData
      property alias particleField: field

      screen: modelData
      visible: root.opened && root.activeParticles > 0
      anchors { top: true; right: true; bottom: true; left: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      mask: Region {}
      WlrLayershell.namespace: "omapower-particles"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      Connections {
        target: root.service
        ignoreUnknownSignals: true
        function onBurstRequested(event) { root.emitBurst(panel, event) }
      }

      function shake(settings) {
        shakeX.stop()
        shakeY.stop()
        field.x = 0
        field.y = 0
        shakeX.to = (Math.random() - 0.5) * 2 * settings.shakeStrength
        shakeY.to = (Math.random() - 0.5) * 2 * settings.shakeStrength
        shakeX.duration = Math.max(10, Math.round(settings.shakeDuration / 2))
        shakeY.duration = shakeX.duration
        shakeX.start()
        shakeY.start()
      }

      HyperPowerCanvas {
        id: field
        anchors.fill: parent
        onParticlesReleased: function(count) {
          root.activeParticles = Math.max(0, root.activeParticles - count)
        }
      }

      SequentialAnimation {
        id: shakeX
        property real to: 0
        property int duration: 45
        NumberAnimation { target: field; property: "x"; to: shakeX.to; duration: shakeX.duration; easing.type: Easing.OutQuad }
        NumberAnimation { target: field; property: "x"; to: 0; duration: shakeX.duration; easing.type: Easing.InOutQuad }
      }

      SequentialAnimation {
        id: shakeY
        property real to: 0
        property int duration: 45
        NumberAnimation { target: field; property: "y"; to: shakeY.to; duration: shakeY.duration; easing.type: Easing.OutQuad }
        NumberAnimation { target: field; property: "y"; to: 0; duration: shakeY.duration; easing.type: Easing.InOutQuad }
      }
    }
  }
}
