import QtQuick

QtObject {
  readonly property var defaults: ({
    particlesEnabled: true,
    particleCount: 5,
    particleLifetime: 480,
    particleSize: 4,
    particleSpread: 130,
    initialVelocity: 170,
    gravity: 250,
    opacity: 0.92,
    maximumActiveParticles: 120,
    shakeEnabled: false,
    shakeStrength: 2,
    shakeDuration: 90,
    particleColorMode: "accent",
    customParticleColor: "#ffffff",
    inputMode: "activity",
    activityResetDelay: 30,
    terminalIdentifiers: ["foot", "footclient", "com.mitchellh.ghostty", "ghostty", "kitty", "alacritty"],
    originXRatio: 0.18,
    originBottomOffset: 52
  })

  function clamp(value, low, high) {
    return Math.max(low, Math.min(high, value))
  }

  function number(value, fallback, low, high) {
    var parsed = Number(value)
    if (!isFinite(parsed)) parsed = fallback
    return clamp(parsed, low, high)
  }

  function boolean(value, fallback) {
    if (value === true || value === false) return value
    if (String(value).toLowerCase() === "true") return true
    if (String(value).toLowerCase() === "false") return false
    return fallback
  }

  function sanitized(raw) {
    raw = raw || {}
    var d = defaults
    var ids = Array.isArray(raw.terminalIdentifiers) ? raw.terminalIdentifiers : d.terminalIdentifiers
    return {
      particlesEnabled: boolean(raw.particlesEnabled, d.particlesEnabled),
      particleCount: Math.round(number(raw.particleCount, d.particleCount, 1, 24)),
      particleLifetime: Math.round(number(raw.particleLifetime, d.particleLifetime, 120, 2000)),
      particleSize: number(raw.particleSize, d.particleSize, 1, 18),
      particleSpread: number(raw.particleSpread, d.particleSpread, 15, 500),
      initialVelocity: number(raw.initialVelocity, d.initialVelocity, 20, 800),
      gravity: number(raw.gravity, d.gravity, -500, 1400),
      opacity: number(raw.opacity, d.opacity, 0.05, 1),
      maximumActiveParticles: Math.round(number(raw.maximumActiveParticles, d.maximumActiveParticles, 8, 500)),
      shakeEnabled: boolean(raw.shakeEnabled, d.shakeEnabled),
      shakeStrength: number(raw.shakeStrength, d.shakeStrength, 0, 12),
      shakeDuration: Math.round(number(raw.shakeDuration, d.shakeDuration, 20, 400)),
      particleColorMode: ["accent", "rainbow", "fixed"].indexOf(String(raw.particleColorMode || "")) >= 0
        ? String(raw.particleColorMode) : d.particleColorMode,
      customParticleColor: /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(String(raw.customParticleColor || ""))
        ? String(raw.customParticleColor) : d.customParticleColor,
      inputMode: ["activity", "socket", "both"].indexOf(String(raw.inputMode || "")) >= 0
        ? String(raw.inputMode) : d.inputMode,
      activityResetDelay: Math.round(number(raw.activityResetDelay, d.activityResetDelay, 10, 250)),
      terminalIdentifiers: ids.map(function(value) { return String(value).toLowerCase() }).filter(function(value) { return value.length > 0 }),
      originXRatio: number(raw.originXRatio, d.originXRatio, 0, 1),
      originBottomOffset: number(raw.originBottomOffset, d.originBottomOffset, 0, 400)
    }
  }
}
