import AppKit
import QuartzCore
import MachineSpiritKit
@testable import MachineSpirit

/// The board and CLI compile the same WindowGeometry.swift.
@main struct PlacementGeometrySmoke {
  @MainActor static func main() async {
    var cases = 0
    for screen in [CGRect(x: 0, y: 38, width: 1728, height: 1000),
                   CGRect(x: -1920, y: -580, width: 1920, height: 1080),
                   CGRect(x: 100, y: 1600, width: 1280, height: 720)] {
      let primaryTop: CGFloat = 1117
      for u in [-0.1, 0, 0.05, 0.0999, 0.1, 0.1001, 0.5, 0.8999, 0.9, 0.9001, 0.95, 1, 1.1] {
        for v in [-0.1, 0, 0.05, 0.0999, 0.1, 0.1001, 0.5, 0.8999, 0.9, 0.9001, 0.95, 1, 1.1] {
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
    // Two private nonactivating windows. The ordinary window has a clear backing;
    // the accessory preview panel is transparent to the user for the whole test.
    _ = NSApplication.shared
    let screen = NSScreen.screens[0]
    let source = CGRect(x: screen.visibleFrame.midX - 170, y: screen.visibleFrame.midY - 110, width: 340, height: 220)
    let fixture = NSPanel(contentRect: source, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
    fixture.level = .normal; fixture.isOpaque = false; fixture.backgroundColor = .clear
    fixture.hasShadow = false; fixture.ignoresMouseEvents = true
    fixture.collectionBehavior = [.stationary, .ignoresCycle]
    fixture.orderFrontRegardless()
    defer { fixture.orderOut(nil) }
    let preview = PlacementPreview(currentOwner: { getpid() })
    let panel = preview.preparePanel()
    panel.alphaValue = 0
    let outline = panel.contentView!.layer!.sublayers!.first!
    let id = CGWindowID(fixture.windowNumber)
    func wait(until predicate: () async -> Bool) async {
      let deadline = ContinuousClock.now + .seconds(2)
      while !(await predicate()) {
        precondition(ContinuousClock.now < deadline, "Timed out waiting for fixture or preview")
        try? await Task.sleep(for: .milliseconds(5))
      }
    }
    await wait { await ObservedWindow.read(pid: getpid(), id: nil)?.id == id }
    let start = await ObservedWindow.read(pid: getpid(), id: id)
    func moveFixture(to frame: CGRect) async {
      fixture.setFrame(frame, display: false)
      let expected = flipScreenRect(frame, primaryTop: screen.frame.maxY)
      await wait {
        guard let actual = await ObservedWindow.read(pid: getpid(), id: id) else { return false }
        return ObservedWindow.matches(actual.frame, expected)
      }
    }
    let fx = OverlayFX(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let action = PlacementIntent(action: .command("open -g \"rectangle://execute-action?name=top-left\""))!
    let state = AppState()
    let leaf = Node(id: "root/q/q/q", key: "q", action: .command("open -g \"rectangle://execute-action?name=top-left\""))
    state.model = Node(id: "root", children: [Node(id: "root/q", key: "q", children: [
      Node(id: "root/q/q", key: "q", children: [leaf])])])
    let delegate = AppDelegate(state: state)
    let prefix = "com.machinespirit.telegraph-test." + UUID().uuidString
    delegate.installOverlayObservers(prefix: prefix, placementPreview: preview)
    let graph = NSApp.windows.first { $0.contentView is OverlayLayerView }!
    graph.contentView!.layer!.opacity = 0
    func send(_ suffix: String, _ payload: [String: String]) {
      DistributedNotificationCenter.default().postNotificationName(Notification.Name(prefix + "." + suffix),
        object: nil, userInfo: payload, deliverImmediately: true)
    }
    defer { DistributedNotificationCenter.default().removeObserver(delegate) }
    send("nav", ["state": "shown", "path": "q/q"])
    await wait { panel.isVisible }
    CATransaction.flush()
    let placement = preview.target!
    precondition(!panel.canBecomeKey && panel.ignoresMouseEvents && outline.opacity > 0 && outline.borderWidth > 0)
    precondition(fixture.frame == source, "Cue must be ordered before the triggering key and before real movement")
    precondition(placement.frame == CGRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.midY,
      width: screen.visibleFrame.width / 2, height: screen.visibleFrame.height / 2))
    send("nav", ["state": "hidden"])
    await wait { !panel.isVisible }
    send("nav", ["state": "shown", "path": "q/q"])
    await wait { panel.isVisible }
    send("fired", ["path": "q/q/q"])
    send("nav", ["state": "hidden"])
    try? await Task.sleep(for: .milliseconds(75))
    precondition(panel.isVisible && outline.opacity == 1, "Early acknowledgment without an actual move")
    await moveFixture(to: placement.frame)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { await wait { outline.animation(forKey: "landing") != nil } }
    await wait { !panel.isVisible }
    // Older tasks must not dismiss a newly armed command, even after their timeout.
    await moveFixture(to: source)
    preview.arm(action, path: "q/q/q", fx: fx)
    await wait { panel.isVisible }
    preview.fire(path: "q/q/q")
    preview.arm(.rectangle(.tr), path: "e/e/e", fx: fx)
    await wait { preview.target?.label == "top-right quarter" }
    try? await Task.sleep(for: .milliseconds(780))
    precondition(panel.isVisible && preview.active)
    preview.fire(path: "e/e/e")
    await wait { !panel.isVisible }
    if let direction = [Placement.displayLeft, .displayRight, .displayUp, .displayDown].first(where: {
      PlacementIntent.arrow($0).destination(window: start!.frame, screens: NSScreen.screens) != nil
    }) {
      preview.arm(.arrow(direction), path: "arrow/arrow", fx: fx)
      await wait { panel.isVisible }
      let destination = preview.target!.frame
      precondition(!screen.frame.intersects(destination))
      preview.fire(path: "arrow/arrow")
      await moveFixture(to: destination)
      if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { await wait { outline.animation(forKey: "landing") != nil } }
      await wait { !panel.isVisible }
    }
    print("PASS \(cases) placement cases; private navigation/fired IPC, real WindowServer fixture, pre-key outline, arrival, cancellation, replacement, refusal timeout and available display transfer")
  }
}
