import AppKit
import QuartzCore
@testable import MachineSpirit

/// The board target and CLI compile the same WindowGeometry.swift.
@main struct PlacementGeometrySmoke {
  @MainActor static func main() {
    var cases = 0
    for screen in [CGRect(x: 0, y: 38, width: 1728, height: 1000),
                   CGRect(x: -1920, y: -580, width: 1920, height: 1080),
                   CGRect(x: 100, y: 1600, width: 1280, height: 720)] {
      let primaryTop: CGFloat = 1117
      for u in [-0.1, 0, 0.05, 0.0999, 0.1, 0.1001, 0.2499, 0.25, 0.2501, 0.5, 0.7499, 0.75, 0.7501, 0.8999, 0.9, 0.9001, 0.95, 1, 1.1] {
        for v in [-0.1, 0, 0.05, 0.0999, 0.1, 0.1001, 0.2499, 0.25, 0.2501, 0.5, 0.7499, 0.75, 0.7501, 0.8999, 0.9, 0.9001, 0.95, 1, 1.1] {
          let mouse = CGPoint(x: screen.minX + screen.width * u, y: screen.maxY - screen.height * v)
          let zone = mouseZone(mouse, visibleFrame: screen)
          let ax = placementFrame(zone, visibleFrame: flipScreenRect(screen, primaryTop: primaryTop), current: .zero)
          let expected = flipScreenRect(ax, primaryTop: primaryTop)
          let actual = SmartPlacement.target(mouse: mouse, visibleFrame: screen).frame
          precondition(abs(actual.minX - expected.minX) < 0.0001 && abs(actual.minY - expected.minY) < 0.0001
                       && actual.size == expected.size, "CLI parity failed at \(mouse)")
          cases += 1
        }
      }
    }
    _ = NSApplication.shared
    let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
    let morph = WindowMorph()
    let panel = NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) } as! NSPanel
    panel.alphaValue = 0 // exercise the real panel without flashing over the user's desktop
    let screen = NSScreen.screens[0].visibleFrame
    let start = screen.insetBy(dx: 60, dy: 60), end = screen.insetBy(dx: 120, dy: 120)
    func cue(_ phase: String, _ id: String, from: CGRect = start, to: CGRect = end,
             age: Double = 0, preview: PlacementPreview? = nil) {
      morph.receive(Notification(name: Notification.Name("fixture"), userInfo: [
        "phase": phase, "id": id, "from": NSStringFromRect(from), "to": NSStringFromRect(to),
        "time": ProcessInfo.processInfo.systemUptime - age]), preview: preview)
    }
    func pump(_ delay: Double) {
      CATransaction.flush()
      RunLoop.main.run(until: Date().addingTimeInterval(delay))
    }
    cue("begin", "stale", age: 1)
    precondition(!panel.isVisible)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      cue("begin", "first")
      precondition(panel.isVisible && !panel.canBecomeKey && panel.ignoresMouseEvents)
      let layer = panel.contentView!.layer!.sublayers!.first!
      pump(0.045)
      let moving = layer.presentation()!
      precondition(moving.opacity > 0 && moving.bounds.width > end.width && moving.bounds.width < start.width)
      pump(0.22)
      precondition(panel.isVisible && layer.opacity > 0.5, "Unconfirmed request vanished")
      cue("begin", "second", from: end, to: start)
      cue("landed", "first")
      pump(0.18)
      precondition(panel.isVisible && layer.opacity > 0.5, "Old landing dismissed a newer move")
      cue("landed", "second")
      pump(0.055)
      precondition(panel.isVisible && layer.presentation()!.opacity > 0 && layer.presentation()!.opacity < 0.72)
      pump(0.14)
      precondition(!panel.isVisible)
      // Consecutive begin/landed packets can be delivered before the next paint.
      cue("begin", "instant")
      cue("landed", "instant")
      let flick = layer.animation(forKey: "dismiss") as? CABasicAnimation
      precondition((flick?.fromValue as? NSNumber)?.doubleValue ?? 0 > 0.5)
      cue("begin", "aborted")
      cue("cancel", "aborted")
      pump(0.12)
      precondition(!panel.isVisible)
      cue("begin", "sender-died")
      pump(WindowMorph.timeout + 0.2)
      precondition(!panel.isVisible)
    }

    let preview = PlacementPreview()
    let aimPanel = preview.preparePanel()
    aimPanel.alphaValue = 0
    let point = CGPoint(x: screen.minX + 5, y: screen.maxY - 5)
    var fx = OverlayFX()
    fx.placementPreview = true
    preview.show(fx: fx)
    preview.commit(at: point, time: ProcessInfo.processInfo.systemUptime)
    preview.leaveNavigation()
    let aimed = preview.target!.frame
    precondition(aimPanel.isVisible && !preview.monitoring)
    cue("begin", "aim", to: aimed, preview: preview)
    pump(0.22)
    precondition(aimPanel.isVisible && !panel.isVisible, "Committed aim must reuse the targeting panel")
    cue("landed", "aim")
    pump(0.2)
    precondition(!aimPanel.isVisible)
    preview.show(fx: fx)
    preview.commit(at: point, time: ProcessInfo.processInfo.systemUptime)
    cue("begin", "instant-aim", to: aimed, preview: preview)
    cue("landed", "instant-aim")
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      let fade = aimPanel.contentView?.layer?.sublayers?.first?.animation(forKey: "dismiss") as? CABasicAnimation
      precondition((fade?.fromValue as? NSNumber)?.doubleValue == 1)
    }
    preview.show(fx: fx)
    preview.commit(at: point, time: ProcessInfo.processInfo.systemUptime)
    cue("begin", "old-aim", to: aimed, preview: preview)
    preview.show(fx: fx)
    cue("landed", "old-aim")
    pump(0.2)
    precondition(aimPanel.isVisible && preview.active, "Old acknowledgment hid a fresh aim")
    preview.leaveNavigation()
    precondition(!aimPanel.isVisible && !preview.monitoring)
    print("PASS \(cases) placement cases against CLI math: all zones, threshold boundaries, negative and stacked screens; confirmed and cancelled landings, interrupted moves, timeout, release handoff")
  }
}
