import QtQuick

Rectangle {
  id: particle

  required property real startX
  required property real startY
  required property real endX
  required property real endY
  required property real controlX
  required property real controlY
  required property int life
  property var release: null

  x: startX - width / 2
  y: startY - height / 2
  radius: Math.max(0.5, width * 0.28)
  transformOrigin: Item.Center

  PathAnimation {
    id: flight
    target: particle
    anchorPoint: Qt.point(particle.width / 2, particle.height / 2)
    duration: particle.life
    orientation: PathAnimation.Fixed
    path: Path {
      startX: particle.startX
      startY: particle.startY
      PathQuad {
        x: particle.endX
        y: particle.endY
        controlX: particle.controlX
        controlY: particle.controlY
      }
    }
  }

  ParallelAnimation {
    id: finish
    NumberAnimation {
      target: particle
      property: "opacity"
      from: particle.opacity
      to: 0
      duration: particle.life
      easing.type: Easing.InQuad
    }
    NumberAnimation {
      target: particle
      property: "scale"
      from: 1
      to: 0.35
      duration: particle.life
      easing.type: Easing.InQuad
    }
  }

  Component.onCompleted: {
    flight.start()
    finish.start()
    expiry.start()
  }

  Timer {
    id: expiry
    interval: particle.life + 12
    repeat: false
    onTriggered: {
      if (particle.release) particle.release()
      particle.destroy()
    }
  }
}
