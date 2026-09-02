import QtQuick

Canvas {
  id: root

  property var particles: []
  property var flashes: []
  property int activeParticleCount: 0
  property int activeFlashCount: 0
  property int paletteCursor: 0
  readonly property var omarchyPalette: [
    "#FFFFFF",
    "#DDF5FF",
    "#A5ECFF",
    "#6DE3FF",
    "#52DFFF",
    "#1AD6FF",
    "#35A6E3",
    "#458FD7",
    "#6561BF",
    "#8632A7"
  ]

  signal particlesReleased(int count)

  renderTarget: Canvas.FramebufferObject
  renderStrategy: Canvas.Immediate
  antialiasing: true

  function smoothstep(edge0, edge1, value) {
    var t = Math.max(0, Math.min(1, (value - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
  }

  function particleColor(settings, accentColor, index, count) {
    if (settings.particleColorMode === "omarchy") {
      var paletteIndex = (paletteCursor + index) % omarchyPalette.length
      return omarchyPalette[paletteIndex]
    }
    if (settings.particleColorMode === "rainbow") {
      var hue = (index / Math.max(1, count) + Math.random() * 0.12) % 1
      return String(Qt.hsla(hue, 0.84, 0.66, 1))
    }
    if (settings.particleColorMode === "fixed") return String(settings.customParticleColor)
    return String(accentColor)
  }

  function addBurst(x, y, settings, capacity, accentColor) {
    var requested = Math.max(1, Math.round(settings.particleCount))
    var count = Math.min(requested, Math.max(0, capacity))
    if (count <= 0) return 0

    var next = particles.slice()
    var spreadScale = settings.particleSpread / 130
    for (var i = 0; i < count; i++) {
      var speed = settings.initialVelocity * (0.94 + Math.random() * 0.12)
      var distribution = count <= 1 ? 0 : i / (count - 1) * 2 - 1
      var horizontalBias = Math.max(-1, Math.min(1, distribution + (Math.random() - 0.5) * 0.14))
      next.push({
        x: x,
        y: y,
        vx: horizontalBias * speed * 0.40 * spreadScale,
        vy: -speed * (0.82 + Math.random() * 0.16),
        gravity: settings.gravity,
        drag: 0.972,
        age: 0,
        life: settings.particleLifetime * (0.94 + Math.random() * 0.12),
        size: settings.particleSize * (0.88 + Math.random() * 0.24),
        opacity: settings.opacity,
        color: particleColor(settings, accentColor, i, count),
        trail: settings.particleTrail
      })
    }
    particles = next
    activeParticleCount = next.length

    if (settings.cursorFlash) {
      var flashNext = flashes.slice()
      flashNext.push({
        x: x,
        y: y,
        age: 0,
        life: 72,
        color: particleColor(settings, accentColor, count, count + 1),
        opacity: settings.opacity
      })
      flashes = flashNext
      activeFlashCount = flashNext.length
    }
    if (settings.particleColorMode === "omarchy")
      paletteCursor = (paletteCursor + count) % omarchyPalette.length

    requestPaint()
    return count
  }

  function clearParticles() {
    var released = particles.length
    particles = []
    flashes = []
    activeParticleCount = 0
    activeFlashCount = 0
    if (released > 0) particlesReleased(released)
    requestPaint()
  }

  function advance(frameSeconds) {
    var dt = Math.max(0.001, Math.min(0.033, Number(frameSeconds) || 1 / 60))
    var elapsedMs = dt * 1000
    var dragFrames = dt * 60
    var alive = []
    var current = particles
    for (var i = 0; i < current.length; i++) {
      var particle = current[i]
      particle.age += elapsedMs
      if (particle.age >= particle.life) continue
      var drag = Math.pow(particle.drag, dragFrames)
      particle.vx *= drag
      particle.vy = particle.vy * drag + particle.gravity * dt
      particle.x += particle.vx * dt
      particle.y += particle.vy * dt
      alive.push(particle)
    }

    var released = current.length - alive.length
    particles = alive
    activeParticleCount = alive.length
    if (released > 0) particlesReleased(released)

    var flashAlive = []
    for (var j = 0; j < flashes.length; j++) {
      var flash = flashes[j]
      flash.age += elapsedMs
      if (flash.age < flash.life) flashAlive.push(flash)
    }
    flashes = flashAlive
    activeFlashCount = flashAlive.length
    requestPaint()
  }

  onPaint: {
    var context = getContext("2d")
    context.clearRect(0, 0, width, height)
    context.save()
    context.globalCompositeOperation = "source-over"

    for (var flashIndex = 0; flashIndex < flashes.length; flashIndex++) {
      var flash = flashes[flashIndex]
      var flashProgress = flash.age / flash.life
      var flashFade = Math.pow(1 - flashProgress, 3.2) * flash.opacity
      var flashHeight = 3.5 + 2.5 * smoothstep(0, 1, flashProgress)
      context.fillStyle = flash.color
      context.globalAlpha = flashFade
      context.fillRect(flash.x - 0.75, flash.y - flashHeight / 2, 1.5, flashHeight)
    }

    for (var particleIndex = 0; particleIndex < particles.length; particleIndex++) {
      var particle = particles[particleIndex]
      var progress = particle.age / particle.life
      var tailFade = 1 - smoothstep(0.58, 1, progress)
      var exponentialFade = Math.pow(0.95, particle.age / 16.667)
      var alpha = particle.opacity * exponentialFade * tailFade
      var pop = progress < 0.07 ? 0.76 + 3.4 * progress : 1
      var shrink = 1 - 0.48 * smoothstep(0.28, 1, progress)
      var size = Math.max(1, particle.size * pop * shrink)
      var px = Math.round(particle.x)
      var py = Math.round(particle.y)

      context.strokeStyle = particle.color
      if (particle.trail && progress < 0.76) {
        var trailTime = 0.018 + 0.009 * (1 - progress)
        context.globalAlpha = alpha * 0.24
        context.lineWidth = Math.max(1, size * 0.34)
        context.beginPath()
        context.moveTo(px, py)
        context.lineTo(
          Math.round(particle.x - particle.vx * trailTime),
          Math.round(particle.y - particle.vy * trailTime)
        )
        context.stroke()
      }

      context.fillStyle = particle.color
      context.globalAlpha = alpha
      context.fillRect(px - size / 2, py - size / 2, size, size)

      if (progress < 0.11) {
        context.fillStyle = "#ffffff"
        context.globalAlpha = alpha * (0.38 - progress * 3.2)
        var hotCore = Math.max(1, size * 0.38)
        context.fillRect(px - hotCore / 2, py - hotCore / 2, hotCore, hotCore)
      }
    }

    context.restore()
  }

  FrameAnimation {
    id: frameLoop
    running: root.activeParticleCount > 0 || root.activeFlashCount > 0
    onTriggered: root.advance(smoothFrameTime)
  }
}
