import AppKit

/// One persisted parameter surface for overlay aesthetics. Read on session open;
/// changing a preference never needs a polling loop or rebuilds the layer pool.
struct OverlayFX {
  var accentHex: String
  var accentColor: NSColor { Self.color(hex: accentHex)! }
  var curvature: Double
  var randomness: Double
  var shake: Double
  var glitch: Double
  var placementPreview: Bool
  var hud: Bool
  var skull: Bool
  var skullGlow: Bool
  var letterPop: Bool
  var shockwave: Bool
  var miss: Bool
  var back: Bool
  var done: Bool
  var hold: Bool
  var close: Bool
  var hover: Bool
  var curvedTraces: Bool
  var openingDuration: Double
  var popDuration: Double
  var shockwaveDuration: Double
  var missDuration: Double
  var backDuration: Double
  var doneDuration: Double
  var holdDuration: Double
  var closeDuration: Double
  var hoverDuration: Double

  init(defaults: UserDefaults = .standard) {
    func flag(_ name: String, _ fallback: Bool = true) -> Bool {
      defaults.object(forKey: "msFX.\(name)") as? Bool ?? fallback
    }
    func duration(_ name: String, _ fallback: Double) -> Double {
      guard let number = defaults.object(forKey: "msFX.\(name)") as? NSNumber,
            number.doubleValue.isFinite else { return fallback }
      return min(2, max(0, number.doubleValue))
    }
    func unit(_ name: String, _ fallback: Double) -> Double {
      min(1, duration(name, fallback))
    }
    let hex = (defaults.object(forKey: "msFX.accentHex") as? String) ?? "#36DE6A"
    accentHex = Self.color(hex: hex) == nil ? "#36DE6A" : hex
    curvature = unit("curvature", 0.4)
    randomness = unit("randomness", 0.35)
    shake = unit("shake", 0.4)
    glitch = unit("glitch", 0.5)
    placementPreview = flag("placementPreview"); hud = flag("hud")
    skull = flag("skull"); skullGlow = flag("skullGlow")
    letterPop = flag("letterPop"); shockwave = flag("shockwave")
    miss = flag("miss"); back = flag("back"); done = flag("done")
    hold = flag("hold"); close = flag("close"); hover = flag("hover")
    curvedTraces = flag("curvedTraces", false)
    openingDuration = duration("openingDuration", 0.14)
    popDuration = duration("popDuration", 0.22)
    shockwaveDuration = duration("shockwaveDuration", 0.38)
    missDuration = duration("missDuration", 0.35)
    backDuration = duration("backDuration", 0.09)
    doneDuration = duration("doneDuration", 0.45)
    holdDuration = duration("holdDuration", 0.16)
    closeDuration = duration("closeDuration", openingDuration * 0.5)
    hoverDuration = duration("hoverDuration", 0.14)
  }
  static func color(hex: String) -> NSColor? {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }),
          let value = UInt32(digits, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
      green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
  }

  static func reset(defaults: UserDefaults = .standard) {
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("msFX.") {
      defaults.removeObject(forKey: key)
    }
  }
}

/// Event-time EMA. Idle time resets the response immediately on the next key.
struct OverlayTempo {
  private var last: CFTimeInterval?
  private var interval: Double?
  mutating func key(at now: CFTimeInterval) -> Double {
    defer { last = now }
    guard let last else { return 0 }
    let elapsed = max(0, now - last)
    let average = elapsed >= 0.45 ? elapsed : (interval.map { 0.55 * elapsed + 0.45 * $0 } ?? elapsed)
    interval = average
    return min(1, max(0, (0.45 - average) / 0.36))
  }
}
