import Foundation

/// One persisted parameter surface for overlay aesthetics. Read on session open;
/// changing a preference never needs a polling loop or rebuilds the layer pool.
struct OverlayFX {
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
    hoverDuration = duration("hoverDuration", 0.10)
  }
}
