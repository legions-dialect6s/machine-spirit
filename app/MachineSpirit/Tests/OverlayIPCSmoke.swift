import AppKit
import QuartzCore
import SwiftUI
import MachineSpiritKit
@testable import MachineSpirit

final class IPCDefaults: UserDefaults, @unchecked Sendable {
  var optedIn = false
  override func bool(forKey key: String) -> Bool { key == "msStatsEnabled" && optedIn }
  override func set(_ value: Any?, forKey key: String) { if key == "msStatsEnabled" { optedIn = value as? Bool ?? false } }
}

/// Real DistributedNotificationCenter delivery to the production delegate,
/// using a private namespace so the installed app never sees the simulation.
/// Optional first argument is a scratch directory for overlay-window captures.
@main struct OverlayIPCSmoke {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    // CA may retain expired animation objects until a later transaction.
    // Check their local end times, not whether the client has pruned its keys.
    func isAnimating(_ layer: CALayer) -> Bool {
      let now = layer.convertTime(CACurrentMediaTime(), from: nil)
      return (layer.animationKeys() ?? []).contains { key in
        guard let a = layer.animation(forKey: key) else { return false }
        return a.repeatCount > 0 || a.repeatDuration > 0 || a.beginTime == 0
          || a.beginTime + a.duration > now
      }
    }
    let defaults = IPCDefaults()
    let stats = StatsStore(defaults: defaults, url: URL(fileURLWithPath: "/dev/null"))
    let state = AppState(stats: stats)
    state.model = Node(id: "root", children: [
      Node(id: "root/a", key: "a", label: "applications", children: [
        Node(id: "root/a/m", key: "m", label: "machine spirit", action: .command("true"), children: [
          Node(id: "root/a/m/x", key: "x", children: [Node(id: "root/a/m/x/y", key: "y")])]),
        Node(id: "root/a/s", key: "s", label: "shell", action: .command("true"))]),
      Node(id: "root/w", key: "w", label: "windows", children: [
        Node(id: "root/w/space", key: "space", label: "smart placement", action: .command("~/bin/ms win place smart"))]),
      Node(id: "root/space", key: "space", label: "place window"),
      Node(id: "root/t", key: "t", label: "terminal")])
    let delegate = AppDelegate(state: state, capsFollower: CapsFollower(readFlags: { [] }))
    let prefix = "com.machinespirit.overlay-test.\(UUID().uuidString)"
    delegate.installOverlayObservers(prefix: prefix)
    let panel = NSApp.windows.first { $0 is NSPanel }!
    func pump(_ seconds: Double = 0.25) { CATransaction.flush(); RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func send(_ suffix: String, _ info: [String: String]) {
      DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("\(prefix).\(suffix)"), object: nil, userInfo: info, deliverImmediately: true)
    }
    func capture(_ name: String, window: NSWindow? = nil) throws {
      guard CommandLine.arguments.count > 1 else { return }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-l", String((window ?? panel).windowNumber), CommandLine.arguments[1] + "/" + name + ".png"]
      try process.run(); process.waitUntilExit()
      precondition(process.terminationStatus == 0, "screencapture needs Screen Recording permission")
    }
    send("nav", ["state": "shown", "path": ""]); pump(0.6)
    precondition(state.overlayVisible && state.overlayNodeID == "root")
    print("DISPLAY scale=\(panel.screen?.backingScaleFactor ?? 0) size=\(panel.frame.size)"); fflush(stdout)
    try capture("root")
    let hoverView = panel.contentView as! OverlayLayerView
    func descendants(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(descendants) }
    hoverView.hover(nil); pump(0.3)
    let nodeLayers = descendants(hoverView.layer!).filter { $0.name != nil && $0.bounds.width == 48 }
    let restPositions = Dictionary(uniqueKeysWithValues: nodeLayers.map { ($0.name!, $0.position) })
    hoverView.hover("root/a/m"); pump(0.35)
    precondition(nodeLayers.contains { $0.opacity > 0 && $0.position != restPositions[$0.name!] })
    try capture("hover-spores")
    print("HOVER settled pid=\(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
    if CommandLine.arguments.count > 1 { pump(8) }
    hoverView.hover(nil); pump(0.35)
    precondition(nodeLayers.allSatisfy { $0.position == restPositions[$0.name!] })
    precondition(descendants(hoverView.layer!).allSatisfy { !isAnimating($0) }, "Hover motion outlasted its duration")
    try capture("hover-out-settled")
    print("RESTORED settled"); fflush(stdout)
    if CommandLine.arguments.count > 1 { pump(8) }
    send("nav", ["state": "shown", "path": "a"]); pump()
    send("nav", ["state": "shown", "path": "a/m"]); pump()
    send("feedback", ["kind": "miss", "path": "a/m"]); pump(0.06)
    try capture("miss")
    send("feedback", ["kind": "back", "path": "a"]); pump()
    precondition(state.overlayNodeID == "root/a")
    send("nav", ["state": "hold", "path": "a/m"]); pump()
    send("fired", ["path": "a/m"]); pump()
    send("feedback", ["kind": "hold", "path": "a/m", "n": "1", "key": "m"]); pump()
    send("feedback", ["kind": "done", "path": "a/m"]); pump(0.08)
    try capture("done")
    pump(0.6)
    precondition(state.overlayVisible && state.overlayNodeID == "root/a/m" && panel.alphaValue == 1)
    precondition(!panel.canBecomeKey && !panel.canBecomeMain && NSApp.keyWindow !== panel)
    precondition(stats.snapshot.totalFires == 0)
    try capture("hold")
    print("VISIBLE settled pid=\(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
    if CommandLine.arguments.count > 1 { pump(8) }
    send("nav", ["state": "hidden"]); pump()
    precondition(!state.overlayVisible && panel.alphaValue == 0 && panel.ignoresMouseEvents)
    print("HIDDEN settled"); fflush(stdout)
    if CommandLine.arguments.count > 1 { pump(8) }
    let view = panel.contentView as! OverlayLayerView
    func layers(_ layer: CALayer?) -> [CALayer] {
      guard let layer else { return [] }
      return [layer] + (layer.sublayers ?? []).flatMap { layers($0) }
    }
    let pool = Set(layers(view.layer).map(ObjectIdentifier.init))
    send("nav", ["state": "shown", "path": ""]); pump(0.07)
    send("nav", ["state": "shown", "path": "a"]); pump(0.07)
    send("nav", ["state": "shown", "path": "a/m"]); pump(0.07)
    send("nav", ["state": "shown", "path": "a/m/x"]); pump(0.07)
    send("nav", ["state": "shown", "path": "a/m/x/y"]); pump(0.02)
    precondition(view.intensity > 0.9, "Fast keys failed to build intensity: \(view.intensity)")
    precondition(layers(view.layer).contains {
      ($0.animation(forKey: "jitter.transform.translation.x") as? CAKeyframeAnimation)?.calculationMode == .discrete
    })
    precondition(layers(view.layer).filter {
      ($0 as? CAShapeLayer)?.path?.boundingBoxOfPath.width == 180 && $0.animation(forKey: "opacity") != nil
    }.count >= 2, "Fast typing did not emit a second ring")
    try capture("fast")
    print("FAST intensity=\(view.intensity)")
    for _ in 0..<5 {
      send("feedback", ["kind": "hold", "path": "a/m/x/y"]); pump(0.07)
    }
    precondition(view.intensity > 0.9, "Repeated successful hold keys lost tempo")
    send("nav", ["state": "hidden"]); pump(0.6)
    send("nav", ["state": "shown", "path": ""]); pump(0.6)
    send("nav", ["state": "shown", "path": "a"]); pump(0.6)
    send("nav", ["state": "shown", "path": "a/m"]); pump(0.02)
    precondition(view.intensity == 0, "Slow keys did not decay intensity")
    try capture("slow")
    print("SLOW intensity=\(view.intensity)")
    send("nav", ["state": "hidden"]); pump(0.6)
    let start = CACurrentMediaTime()
    send("nav", ["state": "shown", "path": ""]); pump(0.035)
    precondition(layers(view.layer).contains { $0.animation(forKey: "summon") != nil })
    send("nav", ["state": "hidden"]); pump(0.16)
    precondition(CACurrentMediaTime() - start < 0.26 && state.overlayVisible && panel.alphaValue == 1,
                 "Short show/hide flickered")
    precondition(!delegate.overlay!.placementPreview.monitoring)
    while state.overlayVisible && CACurrentMediaTime() - start < 0.6 {
      pump(0.005)
      if !state.overlayVisible {
        precondition(CACurrentMediaTime() - start >= 0.260, "Scene closed before 260ms")
      }
    }
    print("DWELL close began after \(CACurrentMediaTime() - start)s")
    precondition(!state.overlayVisible && panel.alphaValue == 1, "Close must begin after dwell, with ghosts visible")
    precondition(view.ghostLayers.contains { $0.animation(forKey: "opacity") != nil })
    try capture("ghost")
    // Capture is a blocking subprocess and may outlast the entire ghost.
    // Exercise interruption separately, without capture latency in the race.
    pump(0.4)
    send("nav", ["state": "shown", "path": ""]); pump(0.4)
    send("nav", ["state": "hidden"]); pump(0.02)
    let rootLayer = layers(view.layer).first { $0.name == "root" }!
    let before = (rootLayer.presentation() ?? rootLayer).position
    send("nav", ["state": "shown", "path": ""]); pump(0.015)
    let after = (rootLayer.presentation() ?? rootLayer).position
    precondition(hypot(before.x - after.x, before.y - after.y) < 1, "Interrupted close moved its anchor")
    pump(0.35)
    precondition(state.overlayVisible && panel.alphaValue == 1, "Cancelled close won")
    send("nav", ["state": "hidden"]); pump(0.5)
    // A pending dwell must also be cancelled by an unchanged path.
    send("nav", ["state": "shown", "path": ""]); pump(0.035)
    send("nav", ["state": "hidden"]); pump(0.035)
    send("nav", ["state": "shown", "path": ""]); pump(0.5)
    precondition(state.overlayVisible && panel.alphaValue == 1)
    send("nav", ["state": "shown", "path": "space"]); pump(0.25)
    let preview = delegate.overlay!.placementPreview
    precondition(preview.active && preview.monitoring)
    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
    let f = screen.visibleFrame
    let positions: [(CGPoint, CGRect, String)] = [
      (CGPoint(x: f.minX + f.width * 0.05, y: f.midY), CGRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height), "left"),
      (CGPoint(x: f.maxX - f.width * 0.05, y: f.maxY - f.height * 0.05), CGRect(x: f.midX, y: f.midY, width: f.width / 2, height: f.height / 2), "top-right"),
      (CGPoint(x: f.midX, y: f.minY + f.height * 0.05), CGRect(x: f.minX, y: f.minY, width: f.width, height: f.height / 2), "bottom"),
      (CGPoint(x: f.midX, y: f.midY), f.insetBy(dx: f.width * 0.05, dy: f.height * 0.05), "center")]
    for (point, expected, name) in positions {
      preview.update(mouse: point); pump(0.2)
      precondition(preview.target?.frame == expected)
      precondition(preview.panel!.ignoresMouseEvents && !preview.panel!.canBecomeKey && !preview.panel!.canBecomeMain)
      try capture("preview-" + name, window: preview.panel)
      if CommandLine.arguments.count > 1, let image = NSBitmapImageRep(data: try Data(contentsOf:
        URL(fileURLWithPath: CommandLine.arguments[1] + "/preview-" + name + ".png"))) {
        let alpha = image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.alphaComponent ?? 1
        precondition(alpha < 0.06, "Placement fill is not faint: \(alpha)")
      }
    }
    send("nav", ["state": "hold", "path": "space"]); pump(0.03)
    precondition(!preview.active && !preview.monitoring && !preview.panel!.isVisible)
    send("nav", ["state": "shown", "path": "space"]); pump(0.03)
    precondition(preview.monitoring)
    send("nav", ["state": "shown", "path": "a"]); pump(0.03)
    precondition(!preview.monitoring)
    send("nav", ["state": "shown", "path": "space"]); pump(0.03)
    send("nav", ["state": "hidden"]); pump(0.5)
    precondition(!preview.monitoring && !preview.active)
    precondition(pool == Set(layers(view.layer).map(ObjectIdentifier.init)), "Wave 2 allocated navigation layers")
    precondition(layers(view.layer).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    var openedBoard = false
    delegate.openBoardAction = { openedBoard = true }
    for status in ["on", "off"] {
      delegate.application(NSApp, open: [URL(string: "machinespirit://hud?style=caps&state=" + status)!])
      pump(0.22)
      let cards = delegate.hud.panels
      precondition(cards.count == NSScreen.screens.count)
      precondition(cards.allSatisfy { $0.ignoresMouseEvents && !$0.canBecomeKey && !$0.canBecomeMain })
      for (i, card) in cards.enumerated() {
        let safe = NSScreen.screens[i].visibleFrame
        precondition(safe.contains(card.frame) && abs(card.frame.midX - safe.midX) < 0.01)
        let glass = card.contentView!.layer!.sublayers![0]
        precondition(glass.bounds.size == CGSize(width: 240, height: 40))
        precondition(abs(safe.maxY - (card.frame.maxY - glass.frame.minY) - 10) < 0.01)
        precondition(abs(glass.backgroundColor!.alpha - 0.6175) < 0.001)
        precondition(glass.borderColor == (status == "on" ? OverlayFX.color(hex: "#FF5A3C")! : OverlayFX().accentColor).withAlphaComponent(0.9).cgColor)
        let title = (glass.sublayers!.last as! CATextLayer).string as! NSAttributedString
        precondition(title.string == (status == "on" ? "CAPS ON" : "CAPS OFF"))
        precondition((title.attribute(.kern, at: 0, effectiveRange: nil) as! Double) == 0.8)
        precondition((title.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).fontName == OverlaySurfaceStyle.displayFont(size: 21).fontName)
        try capture("caps-\(status)-\(i)", window: card)
      }
      pump(1.65)
      precondition(cards.allSatisfy { !$0.isVisible }, "Caps HUD did not expire")
    }
    delegate.application(NSApp, open: [URL(string: "machinespirit://hud?style=caps&state=on")!]); pump(0.7)
    let replaced = delegate.hud.panels
    delegate.application(NSApp, open: [URL(string: "machinespirit://hud?style=caps&state=off")!]); pump(0.8)
    precondition(zip(replaced, delegate.hud.panels).allSatisfy { $0 === $1 } && replaced.allSatisfy(\.isVisible),
                 "An old HUD deadline dismissed its replacement")
    pump(0.9)
    // Reverse a fade without replacing windows or letting an old completion hide them.
    delegate.application(NSApp, open: [URL(string: "machinespirit://hud?style=caps&state=on")!]); pump(0.3)
    let fading = delegate.hud.panels
    delegate.hud.dismiss(); pump(0.07)
    delegate.application(NSApp, open: [URL(string: "machinespirit://hud?style=caps&state=off")!]); pump(0.3)
    precondition(zip(fading, delegate.hud.panels).allSatisfy { $0 === $1 } && fading.allSatisfy(\.isVisible))
    precondition(fading.allSatisfy { $0.contentView!.layer!.sublayers![0].frame.minY == 10 },
                 "Reversing a fade shifted pill geometry")
    pump(1.4)
    delegate.application(NSApp, open: [URL(string: "machinespirit://hud?style=text")!])
    precondition(delegate.hud.panels.isEmpty, "Empty payload showed default prose")
    let textURL = URL(string: "machinespirit://hud?style=text&title=Translation&text=Hola%20mundo%20%E2%86%92%20Hello%20world")!
    delegate.application(NSApp, open: [textURL]); pump(0.22)
    let card = delegate.hud.panels[0]
    precondition(!card.ignoresMouseEvents && !card.canBecomeKey && card.frame.width <= 420)
    let textLayers = descendants(card.contentView!.layer!).compactMap { $0 as? CATextLayer }
    let bodyText = textLayers.last!.string as! NSAttributedString
    let bodyFont = bodyText.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
    precondition(bodyFont.pointSize == 13 && !bodyFont.isFixedPitch)
    precondition(bodyText.string == "Hola mundo → Hello world")
    try capture("hud-text", window: card)
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 10),
      modifierFlags: [], timestamp: 0, windowNumber: card.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    card.contentView!.mouseDown(with: click); pump(0.3)
    precondition(!card.isVisible, "Text card did not dismiss on click")
    delegate.application(NSApp, open: [textURL]); pump(0.1)
    let expiredCard = delegate.hud.panels[0]
    pump(9.5)
    precondition(expiredCard.isVisible, "Text card expired early")
    pump(0.9)
    precondition(!expiredCard.isVisible, "Text card did not expire after 10 seconds")
    precondition(!openedBoard && !state.boardOpen && NSApp.keyWindow == nil)
    print("PASS wave 2: 70ms/600ms IPC, 260ms dwell, interrupted close, pooled ghosts/slices, four preview zones + monitor cleanup, both HUD styles + click/expiry + board isolation")
    let graphics = OverlaySurfacePanel()
    graphics.setFrame(CGRect(x: screen.visibleFrame.midX - 230, y: screen.visibleFrame.midY - 140,
                             width: 460, height: 280), display: false)
    graphics.contentView = NSHostingView(rootView: GraphicsSettings(expanded: true)
      .padding(12).frame(width: 460, height: 280).background(Theme.ground).preferredColorScheme(.dark))
    graphics.orderFrontRegardless(); pump(0.4)
    try capture("graphics", window: graphics)
    graphics.orderOut(nil)
    defaults.optedIn = true
    send("fired", ["path": "a/m"]); pump(0.05)
    precondition(stats.snapshot.totalFires == 1 && stats.snapshot.firesPerPath == ["a/m": 1])
    delegate.application(NSApp, open: [URL(string: "machinespirit://fired?path=a/m")!])
    precondition(stats.snapshot.totalFires == 1, "Legacy URL double-counted stats")
    stats.disable()
    state.selectedNodeID = "root/a/m"; state.pan = CGSize(width: 71, height: -53); state.zoom = 1.7
    state.closeBoard(persist: false)
    precondition(state.selectedNodeID == "root/a/m" && state.pan.width == 71 && state.pan.height == -53 && state.zoom == 1.7)
    DistributedNotificationCenter.default().removeObserver(delegate)
    panel.orderOut(nil)
    print("PASS real IPC shown → a → a/m → miss → back → hold → done → hidden; non-key panel; stats opt-out; viewport preserved")
  }
}
