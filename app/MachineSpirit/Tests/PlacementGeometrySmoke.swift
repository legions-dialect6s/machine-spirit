import AppKit
import QuartzCore
import MachineSpiritKit
@testable import MachineSpirit

/// The board and CLI compile the same WindowGeometry.swift.
@main struct PlacementGeometrySmoke {
  @MainActor static func main() async throws {
    var cases = 0
    let notchedDisplay = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let notchedFullscreen = CGRect(x: 0, y: 33, width: 1728, height: 1084)
    let notchedUsable = CGRect(x: 0, y: 33, width: 1728, height: 1027)
    precondition(ObservedWindow.fillsFullscreenArea(notchedFullscreen, display: notchedDisplay, usable: notchedUsable))
    precondition(!ObservedWindow.fillsFullscreenArea(notchedUsable, display: notchedDisplay, usable: notchedUsable))
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
    let preview = PlacementPreview(currentOwner: { getpid() }, runningPID: { _ in getpid() },
                                   queryFocused: { pid, _ in await ObservedWindow.read(pid: pid, id: nil) })
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
    if let other = NSScreen.screens.first(where: { $0 != screen }),
       UserDefaults(suiteName: "com.knollsoft.Rectangle")?.bool(forKey: "useCursorScreenDetection") != true {
      let ddd = PlacementIntent(action: .command("open -g \"rectangle://execute-action?name=right-half\""))!
      let point = CGPoint(x: other.frame.midX, y: other.frame.midY)
      let (placement, destination) = ddd.destination(window: start!.frame, screens: NSScreen.screens, cursor: point)!
      precondition(destination == screen && placement.label.contains(screen.localizedName),
                   "DDD follows the source window when the pointer is on another display")
      precondition(placement.frame.midX > screen.visibleFrame.midX)
    }
    for (mode, expected) in [("amm", screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.05,
                                                                 dy: screen.visibleFrame.height * 0.05)),
                             ("max", screen.visibleFrame)] {
      let intent = PlacementIntent(action: .command("~/bin/run-quiet.sh ~/bin/ms win place \(mode)"))!
      let actual = intent.destination(window: start!.frame, screens: NSScreen.screens)!.0.frame
      precondition(ObservedWindow.matches(actual, expected), "Expected \(expected), got \(actual)")
    }
    precondition(LaunchCue(action: .command("~/bin/run-quiet.sh ~/bin/tmux-launch.sh")) == .freshTerminal)
    precondition(LaunchCue(action: .command("~/bin/run-quiet.sh ~/bin/messages-find.sh")) == .focus("com.apple.MobileSMS"))
    let state = AppState()
    let leaf = Node(id: "root/q/q/q", key: "q", action: .command("open -g \"rectangle://execute-action?name=top-left\""))
    let shot = Node(id: "root/s/s/s/s", key: "s",
                    action: .command("~/bin/run-quiet.sh ~/bin/screenshots/ss-sel-save.sh"))
    precondition(shot.overlayLabel == "Save screenshot")
    state.model = Node(id: "root", children: [
      Node(id: "root/q", key: "q", children: [Node(id: "root/q/q", key: "q", children: [leaf])]),
      Node(id: "root/s", key: "s", children: [Node(id: "root/s/s", key: "s", children: [
        Node(id: "root/s/s/s", key: "s", children: [shot])
      ])])
    ])
    for (key, side) in [("a", "left"), ("d", "right")] {
      let group = "root/" + key
      let gate = group + "/" + key
      let leaf = Node(id: gate + "/" + key, key: key,
                      action: .command("~/bin/ms win rectangle \"rectangle://execute-action?name=\(side)-half\""))
      state.model?.children.append(Node(id: group, key: key, children: [Node(id: gate, key: key, children: [leaf])]))
    }
    let delegate = AppDelegate(state: state)
    let prefix = "com.machinespirit.telegraph-test." + UUID().uuidString
    delegate.installOverlayObservers(prefix: prefix, placementPreview: preview)
    let graph = NSApp.windows.first { $0.contentView is OverlayLayerView }!
    graph.contentView!.layer!.opacity = 0
    func send(_ suffix: String, _ payload: [String: Any]) {
      DistributedNotificationCenter.default().postNotificationName(Notification.Name(prefix + "." + suffix),
        object: nil, userInfo: payload, deliverImmediately: true)
    }
    func capturePanel(_ window: NSWindow, environmentKey: String) async throws {
      guard let capture = ProcessInfo.processInfo.environment[environmentKey] else { return }
      CATransaction.flush()
      try await Task.sleep(for: .milliseconds(100))
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-l", String(window.windowNumber), capture]
      try process.run()
      process.waitUntilExit()
      precondition(process.terminationStatus == 0, "Could not capture requested fixture panel")
    }
    defer { DistributedNotificationCenter.default().removeObserver(delegate) }
    for (key, side) in [("a", Placement.left), ("d", Placement.right)] {
      let pair = key + "/" + key
      send("nav", ["state": "shown", "path": key])
      await wait { preview.sourcePanel?.isVisible == true }
      precondition(!panel.isVisible, "The first key identifies only the selected window")
      send("nav", ["state": "shown", "path": pair])
      await wait { panel.isVisible }
      let expected = placementFrame(side, visibleFrame: screen.visibleFrame, current: source)
      precondition(ObservedWindow.matches(preview.target!.frame, expected))
      send("fired", ["path": pair + "/" + key])
      send("nav", ["state": "hidden"])
      await moveFixture(to: expected)
      await wait { outline.animation(forKey: "landing") != nil }
      precondition(preview.sourcePanel!.isVisible)
      await wait { !panel.isVisible }
      await moveFixture(to: source)
    }
    send("nav", ["state": "shown", "path": "q/q"])
    await wait { panel.isVisible }
    CATransaction.flush()
    let placement = preview.target!
    precondition(!panel.canBecomeKey && panel.ignoresMouseEvents && outline.opacity > 0 && outline.borderWidth > 0)
    let origin = preview.sourcePanel!
    precondition(origin.isVisible && !origin.canBecomeKey && origin.ignoresMouseEvents)
    precondition(ObservedWindow.matches(origin.frame, fixture.frame))
    precondition((origin.contentView?.layer?.sublayers?.first as? CAShapeLayer)?.lineDashPattern == [5, 4])
    origin.alphaValue = 0
    precondition(ObservedWindow.matches(fixture.frame, source),
                 "Cue moved the fixture before the triggering key. Expected \(source), saw \(fixture.frame)")
    precondition(placement.frame == CGRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.midY,
      width: screen.visibleFrame.width / 2, height: screen.visibleFrame.height / 2))
    send("nav", ["state": "hidden"])
    await wait { !panel.isVisible }
    precondition(!origin.isVisible)
    send("nav", ["state": "shown", "path": "q/q"])
    await wait { panel.isVisible }
    send("fired", ["path": "q/q/q"])
    send("nav", ["state": "hidden"])
    try? await Task.sleep(for: .milliseconds(75))
    precondition(origin.isVisible)
    precondition(panel.isVisible && outline.opacity == 1, "Early acknowledgment without an actual move")
    await moveFixture(to: placement.frame)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { await wait { outline.animation(forKey: "landing") != nil } }
    await wait { !panel.isVisible }
    // Rectangle owns repeat history. The board follows the same window to its actual landing.
    preview.arm(action, path: "q/q/q", fx: fx)
    await wait { origin.isVisible }
    precondition(!panel.isVisible)
    preview.fire(path: "q/q/q")
    let landed = NSScreen.screens.dropFirst().first?.visibleFrame.insetBy(dx: 60, dy: 50) ?? source
    await moveFixture(to: landed)
    await wait { panel.isVisible && outline.animation(forKey: "landing") != nil }
    precondition(ObservedWindow.matches(preview.target!.frame, fixture.frame))
    await wait { !panel.isVisible }
    // A command-side receipt also works when the next key beat the prefix read.
    let axSource = flipScreenRect(source, primaryTop: screen.frame.maxY)
    send("placement", ["pid": getpid(), "windowID": id, "frame": NSStringFromRect(axSource), "mode": "amm"])
    await wait { panel.isVisible }
    await moveFixture(to: source)
    await wait { outline.animation(forKey: "landing") != nil }
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      precondition(outline.animation(forKey: "settle") != nil && outline.animation(forKey: "landing")!.duration >= 0.27)
    }
    await wait { !panel.isVisible }
    // Older tasks must not dismiss a newly armed command, even after their timeout.
    await moveFixture(to: source)
    preview.arm(action, path: "q/q/q", fx: fx)
    await wait { panel.isVisible }
    preview.fire(path: "q/q/q")
    preview.arm(.rectangle(.tr), path: "e/e/e", fx: fx)
    await wait { preview.target?.label.hasPrefix("top-right quarter") == true }
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
      precondition(preview.target!.label.hasPrefix(screen.localizedName + " → "))
      preview.fire(path: "arrow/arrow")
      await moveFixture(to: destination)
      if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { await wait { outline.animation(forKey: "landing") != nil } }
      await wait { !panel.isVisible }
    }
    await moveFixture(to: source)
    if NSScreen.screens.count > 1 {
      let intent = PlacementIntent(action: .command("~/bin/run-quiet.sh ~/bin/ms win place display-next"))!
      preview.arm(intent, path: "f/f/f", fx: fx)
      await wait { panel.isVisible }
      let destination = preview.target!.frame
      let actualScreen = NSScreen.screens.first { $0.visibleFrame.contains(destination) }!
      precondition(actualScreen != screen && destination != actualScreen.visibleFrame)
      preview.fire(path: "f/f/f")
      // A fixed-size window can land with a different size than requested.
      let clamped = destination.insetBy(dx: 14, dy: 10)
      await moveFixture(to: clamped)
      await wait { outline.animation(forKey: "landing") != nil }
      precondition(ObservedWindow.matches(preview.target!.frame, clamped))
      await wait { !panel.isVisible }
    }
    let halfDown = PlacementIntent(action: .command("~/bin/run-quiet.sh ~/bin/ms win place half-down"))!
    await moveFixture(to: source)
    preview.arm(halfDown, path: "x/x/x", fx: fx)
    await wait { panel.isVisible }
    let lowerHalf = CGRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY,
                           width: screen.visibleFrame.width, height: screen.visibleFrame.height / 2)
    precondition(ObservedWindow.matches(preview.target!.frame, lowerHalf))
    preview.hide()

    let miss = "No display directly below this window"
    send("placement.miss", ["reason": miss])
    await wait { preview.errorPanel?.isVisible == true }
    let errorPanel = preview.errorPanel!
    let border = errorPanel.contentView!.layer!.sublayers!.first!
    let message = border.sublayers!.first! as! CATextLayer
    let textWidth = (miss as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)]).width
    precondition(message.string as? String == miss && message.bounds.width > textWidth)
    precondition(message.truncationMode == .none && message.backgroundColor == nil && border.backgroundColor == nil)
    precondition(NSColor(cgColor: border.borderColor!)!.redComponent == 1)
    try await capturePanel(errorPanel, environmentKey: "MS_ERROR_CAPTURE")
    try? await Task.sleep(for: .milliseconds(800))
    send("placement.miss", ["reason": miss])
    try? await Task.sleep(for: .milliseconds(750))
    precondition(preview.errorPanel === errorPanel && errorPanel.isVisible && border.opacity == 1)
    await wait { !errorPanel.isVisible }

    func findLayer(_ layer: CALayer?, named name: String) -> CALayer? {
      guard let layer else { return nil }
      if layer.name == name { return layer }
      return layer.sublayers?.lazy.compactMap { findLayer($0, named: name) }.first
    }
    send("nav", ["state": "shown", "path": "s/s"])
    await wait { state.overlayNodeID == "root/s/s" }
    let shotDisc = findLayer(graph.contentView?.layer, named: shot.id)!.sublayers!.first!
    let previewColor = shotDisc.borderColor
    send("nav", ["state": "shown", "path": "s/s/s"])
    await wait { state.overlayNodeID == "root/s/s/s" }
    precondition(shotDisc.borderColor != previewColor, "Interactive screenshot is highlighted before the final key")
    if ProcessInfo.processInfo.environment["MS_GRAPH_CAPTURE"] != nil {
      graph.contentView!.layer!.opacity = 1
      try await Task.sleep(for: .milliseconds(220))
      try await capturePanel(graph, environmentKey: "MS_GRAPH_CAPTURE")
      graph.contentView!.layer!.opacity = 0
    }
    send("nav", ["state": "hidden"])
    await wait { !state.overlayVisible }
    send("window.focus", ["pid": getpid(), "windowID": id])
    await wait { panel.isVisible && outline.animation(forKey: "landing") != nil }
    precondition(ObservedWindow.matches(preview.target!.frame, fixture.frame))
    await wait { !panel.isVisible }
    preview.prepareLaunch(for: [.freshTerminal])
    try? await Task.sleep(for: .milliseconds(50))
    preview.launch(.freshTerminal, path: "t/t", fx: fx)
    try? await Task.sleep(for: .milliseconds(100))
    precondition(!panel.isVisible, "The existing terminal must not acknowledge the new window")
    let second = NSPanel(contentRect: source, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    second.level = .normal; second.backgroundColor = .clear; second.isOpaque = false
    second.hasShadow = false; second.ignoresMouseEvents = true; second.orderFrontRegardless()
    defer { second.orderOut(nil) }
    await wait { panel.isVisible && outline.animation(forKey: "landing") != nil }
    precondition(ObservedWindow.matches(preview.target!.frame, second.frame))
    await wait { !panel.isVisible }
    preview.launch(.focus("com.apple.MobileSMS"), path: "m/e", fx: fx)
    await wait { panel.isVisible && outline.animation(forKey: "landing") != nil }
    await wait { !panel.isVisible }
    print("PASS \(cases) placement cases; real WindowServer fixture, private navigation/fired IPC, DDD source display, arrival, cancellation, replacement, refusal timeout, display transfer when available, half-step, repeated readable error, screenshot route arming and focus")
  }
}
