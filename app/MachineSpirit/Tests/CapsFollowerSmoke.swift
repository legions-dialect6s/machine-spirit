import AppKit
import QuartzCore
@testable import MachineSpirit

private final class CapsDefaults: UserDefaults, @unchecked Sendable {
  var values: [String: Any] = [:]
  override func object(forKey key: String) -> Any? { values[key] }
  override func set(_ value: Any?, forKey key: String) {
    values[key] = value
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
  }
}

/// Uses the production delegate and real event monitors, but injected HID state
/// and memory-only defaults. Never routes test URLs through LaunchServices.
@main struct CapsFollowerSmoke {
  @MainActor static func main() throws {
    if CommandLine.arguments.contains("--drive") {
      let x = Double(CommandLine.arguments[2])!, y = Double(CommandLine.arguments[3])!
      let began = CACurrentMediaTime()
      for index in 0..<1200 {
        let angle = Double(index) * 0.025
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
          mouseCursorPosition: CGPoint(x: x + cos(angle) * 80, y: y + sin(angle) * 60), mouseButton: .left)!
        event.post(tap: .cghidEventTap)
        Thread.sleep(until: Date(timeIntervalSinceNow: max(0, began + Double(index + 1) / 120 - CACurrentMediaTime())))
      }
      print("DRIVER posted 1200 mouseMoved events in \(CACurrentMediaTime() - began)s")
      return
    }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let output = CommandLine.arguments[1]
    func pump(_ seconds: Double = 0.25) {
      CATransaction.flush()
      let until = Date(timeIntervalSinceNow: seconds)
      // Drain the AppKit queue as a real NSApplication.run would; a bare
      // RunLoop wait doesn't dispatch NSEvent global/local monitor callbacks.
      repeat {
        if let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
          NSApp.sendEvent(event)
        }
      } while Date() < until
    }
    let defaults = CapsDefaults()
    var flags: CGEventFlags = []
    var reads = 0
    let follower = CapsFollower(defaults: defaults, readFlags: { reads += 1; return flags })
    defer { follower.stop() }
    let delegate = AppDelegate(state: AppState(), capsFollower: follower)
    func url(_ state: String, hardware: Bool) {
      flags = hardware ? .maskAlphaShift : []
      delegate.application(NSApp, open: [URL(string: "machinespirit://hud?style=caps&state=" + state)!])
      delegate.hud.dismiss(animated: false)
    }
    follower.start(); follower.start()
    precondition(reads == 1 && follower.panel == nil && follower.mouseMonitorCount == 0)
    precondition(follower.flagsMonitorCount == 2)
    pump(0.3); precondition(reads == 1, "OFF polled HID")
    weak var releasedWindow: NSWindow?
    autoreleasepool {
      url("on", hardware: true); pump()
      releasedWindow = follower.panel
      precondition(follower.capsOn && follower.panel?.isVisible == true && follower.mouseMonitorCount == 2)
      precondition(!delegate.state.boardOpen)
      do {
        let panel = follower.panel!
        precondition(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain)
        precondition(panel.styleMask.contains(.nonactivatingPanel) && panel.styleMask.contains(.borderless))
        precondition(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        precondition(panel.level.rawValue == Int(CGWindowLevelForKey(.statusWindow)))
        precondition(panel.frame.size == CGSize(width: 36, height: 26))
        let card = panel.contentView!.layer!.sublayers![0]
        precondition(card.frame == CGRect(x: 4, y: 4, width: 28, height: 18))
        precondition(abs(card.backgroundColor!.alpha - 0.6175) < 0.0001)
        let glyph = card.sublayers![0] as! CATextLayer
        let text = glyph.string as! NSAttributedString
        precondition(text.string == "⇪")
        precondition((text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor)
          == OverlayFX.color(hex: "#FF5A3C")!)
        url("on", hardware: true)
        precondition(follower.panel === panel && follower.mouseMonitorCount == 2)
        url("off", hardware: false)
        precondition(follower.mouseMonitorCount == 0)
        precondition(abs(panel.contentView!.layer!.animation(forKey: "capsFade")!.duration - 0.15) < 0.001)
        pump(0.04); url("on", hardware: true); pump(0.25)
        precondition(follower.panel === panel && panel.isVisible && panel.contentView!.layer!.opacity == 1)
      }
      url("off", hardware: false); pump(0.35)
    }
    precondition(follower.panel == nil && releasedWindow == nil && follower.mouseMonitorCount == 0,
      "OFF retained its window or mouse monitors")
    // Hardware wins over stale URLs, and text HUD arrivals also reconcile.
    url("on", hardware: false); precondition(follower.panel == nil)
    url("off", hardware: true); precondition(follower.panel != nil)
    flags = []
    delegate.application(NSApp, open: [URL(string: "machinespirit://hud?style=text")!]); pump(0.3)
    precondition(follower.panel == nil)
    // Real local flagsChanged delivery, including toggles while our board owns focus.
    func postFlags(_ value: NSEvent.ModifierFlags) {
      flags = value.contains(.capsLock) ? .maskAlphaShift : []
      let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: value,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 57)!
      NSApp.postEvent(event, atStart: false); pump()
    }
    postFlags(.capsLock); precondition(follower.capsOn && follower.panel != nil)
    postFlags([.capsLock, .shift]); precondition(follower.mouseMonitorCount == 2)
    postFlags([]); precondition(!follower.capsOn && follower.panel == nil)
    flags = .maskAlphaShift
    follower.stop(); follower.start()
    precondition(follower.panel != nil, "Launch while Caps ON missed hardware state")
    defaults.set(false, forKey: "msFX.capsFollower"); pump(0.3)
    precondition(follower.capsOn && follower.panel == nil && follower.mouseMonitorCount == 0)
    defaults.set(true, forKey: "msFX.capsFollower"); pump()
    precondition(follower.panel != nil && follower.mouseMonitorCount == 2)
    // Display edges, negative origins, and mixed backing scales.
    for (index, screen) in NSScreen.screens.enumerated() {
      let middle = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
      follower.move(to: middle)
      precondition(abs(follower.panel!.frame.minX - middle.x - 10) <= 1
        && abs(follower.panel!.frame.minY - middle.y + 40) <= 1, "AppKit-rounded pointer offset")
      let glyph = follower.panel!.contentView!.layer!.sublayers![0].sublayers![0]
      precondition(glyph.contentsScale == screen.backingScaleFactor)
      for x in [screen.frame.minX + 1, screen.frame.maxX - 1] {
        for y in [screen.frame.minY + 1, screen.frame.maxY - 1] {
          let point = CGPoint(x: x, y: y)
          follower.move(to: point)
          precondition(screen.frame.contains(follower.panel!.frame))
          precondition(!follower.panel!.frame.contains(point))
        }
      }
      follower.move(to: middle); pump()
      let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      capture.arguments = ["-x", "-l", String(follower.panel!.windowNumber), output + "/caps-follower-\(index).png"]
      try capture.run(); capture.waitUntilExit(); precondition(capture.terminationStatus == 0)
    }
    let savedMouse = NSEvent.mouseLocation
    let mainTop = NSScreen.screens[0].frame.maxY
    defer { CGWarpMouseCursorPosition(CGPoint(x: savedMouse.x, y: mainTop - savedMouse.y)) }
    let screen = NSScreen.main!
    // Exercise the local path too, including dragging without synthesizing a
    // real button press or delivering a drag to another application.
    for type in [NSEvent.EventType.mouseMoved, .leftMouseDragged] {
      follower.move(to: CGPoint(x: screen.frame.midX - 100, y: screen.frame.midY))
      let before = follower.panel!.frame.origin
      CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: mainTop - screen.frame.midY))
      let event = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: .capsLock,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
        eventNumber: 1, clickCount: 0, pressure: 0)!
      NSApp.postEvent(event, atStart: false); pump(0.1)
      precondition(follower.panel!.frame.origin != before, "Local mouse/drag monitor missed event")
    }
    let driver = Process()
    driver.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    driver.arguments = ["--drive", String(Double(screen.frame.midX)), String(Double(mainTop - screen.frame.midY))]
    try driver.run()
    print("FOLLOWER MOVING pid=\(ProcessInfo.processInfo.processIdentifier) target=120 events/s"); fflush(stdout)
    var changed = 0
    for _ in 0..<90 {
      let before = follower.panel!.frame.origin
      pump(0.1)
      if follower.panel!.frame.origin != before { changed += 1 }
    }
    while driver.isRunning { pump(0.1) }
    precondition(driver.terminationStatus == 0 && changed > 60,
      "Synthetic global mouse events were not delivered to the follower")
    let expected = CapsFollower.origin(mouse: NSEvent.mouseLocation, screen: screen.frame)
    precondition(abs(follower.panel!.frame.minX - expected.x) <= 1
      && abs(follower.panel!.frame.minY - expected.y) <= 1)
    print("GLOBAL mouse delivery observed in \(changed)/90 samples"); fflush(stdout)
    url("off", hardware: false); pump(0.4)
    precondition(follower.panel == nil && follower.mouseMonitorCount == 0)
    let offReads = reads
    print("FOLLOWER OFF settled"); fflush(stdout)
    pump(8)
    precondition(reads == offReads && follower.panel == nil && follower.mouseMonitorCount == 0)
    follower.stop()
    precondition(follower.flagsMonitorCount == 0 && follower.mouseMonitorCount == 0)
    print("PASS caps follower URL/HID reconciliation, launch, flags events, preferences, rapid reversal, release, screens, real mouse delivery, OFF idle")
  }
}
