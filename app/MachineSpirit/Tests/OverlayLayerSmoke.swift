import AppKit
import QuartzCore
import MachineSpiritKit
@testable import MachineSpirit

// After xcodebuild, link this harness to the Debug app's testable dylib.
// Does not read/write the live config or execute any binds.
@main struct OverlayLayerSmoke {
  @MainActor static func main() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let root = Node(id: "root", children: [
      Node(id: "root/a", key: "a", children: [Node(id: "root/a/x", key: "x",
        label: "A long explicit label 👨‍👩‍👧‍👦 with more text", action: .application(path: "/Applications/Example.app"))]),
      Node(id: "root/b", key: "b", children: [Node(id: "root/b/y", key: "y")])
    ])
    precondition(root.children[0].boardLabel == root.children[0].children[0].label)
    precondition(root.children[0].overlayLabel.count == 22 && root.children[0].overlayLabel.hasSuffix("…"))
    precondition(Node(id: "root/c", key: "c", children: [Node(id: "root/c/x"), Node(id: "root/c/y")]).boardLabel == "c")
    precondition(Node(id: "root/app", label: " ", action: .application(path: "/Applications/Example.app")).boardLabel == "open app Example")
    precondition(Node(id: "root/unnamed").boardLabel == "group")
    precondition(Node(id: "root/a", key: "a", children: [Node(id: "root/a/#0")]).boardLabel == "a")
    precondition(Node(id: "root", children: [Node(id: "root/#0")]).boardLabel == "gate")
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
    let state = AppState()
    state.model = root
    let overlay = TypingOverlay(state: state)
    let panel = NSApp.windows.first { $0 is NSPanel }!
    panel.contentView?.layer?.opacity = 0 // Exercise real layers without drawing over the desktop.
    func pump(_ seconds: Double = 0.24) { CATransaction.flush(); RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func layers(_ layer: CALayer?) -> [CALayer] {
      guard let layer else { return [] }
      return [layer] + (layer.sublayers ?? []).flatMap { layers($0) }
    }
    let initial = Set(layers(panel.contentView?.layer).map(ObjectIdentifier.init))
    let gradients = layers(panel.contentView?.layer).compactMap { $0 as? CAGradientLayer }
    precondition(gradients.count == 1 && gradients[0].type == .radial)
    let backdrop = gradients[0]
    precondition(layers(panel.contentView?.layer).compactMap { $0 as? CAShapeLayer }
      .filter { $0.path?.boundingBoxOfPath.width == 180 }.count == 3, "Ring pool must have exactly three layers")
    precondition(backdrop.superlayer?.sublayers?.first === backdrop, "Backdrop must sit behind the graph")
    for _ in 0..<50 { overlay.show(path: "", screen: nil); overlay.hide() }
    for i in 0..<50 { overlay.show(path: i % 2 == 0 ? "a" : "b", screen: nil) }
    overlay.show(path: "a", screen: nil)
    pump()
    precondition(state.overlayVisible && state.overlayNodeID == "root/a")
    let focus = layers(panel.contentView?.layer).first {
      $0.zPosition == 2 && $0.bounds.width == 48
    }!
    precondition(backdrop.position == focus.position && backdrop.bounds.width == backdrop.bounds.height)
    precondition(initial == Set(layers(panel.contentView?.layer).map(ObjectIdentifier.init)), "Navigation rebuilt layers")
    precondition(panel.frame == panel.screen!.frame && !panel.canBecomeKey && !panel.canBecomeMain)
    precondition(panel.level.rawValue > Int(CGWindowLevelForKey(.statusWindow)))
    precondition(layers(panel.contentView?.layer).allSatisfy { $0.contentsScale == panel.screen!.backingScaleFactor })
    func checkNodeTravel(_ expected: TimeInterval) {
      let animations = layers(panel.contentView?.layer).filter { $0.name != nil && $0.bounds.width == 48 }
        .compactMap { $0.animation(forKey: "position") }
      precondition(!animations.isEmpty && animations.allSatisfy { abs($0.duration - expected) < 0.001 },
                   "Node navigation stopped honoring its configured duration")
    }
    overlay.show(path: "a/x", screen: nil); pump(0.02)
    checkNodeTravel(0.14)
    precondition(layers(panel.contentView?.layer).contains { $0.animation(forKey: "pop") is CASpringAnimation })
    pump(0.20)
    overlay.show(path: "a", screen: nil); pump(0.02)
    checkNodeTravel(0.09)
    pump()
    overlay.feedback(kind: "miss", path: "a"); pump(0.02)
    precondition(layers(panel.contentView?.layer).contains { $0.animation(forKey: "feedbackPulse") != nil })
    overlay.feedback(kind: "done", path: "a"); pump(0.02)
    precondition(layers(panel.contentView?.layer).contains { $0.animation(forKey: "feedbackColor.strokeColor") != nil })
    overlay.feedback(kind: "back", path: ""); pump()
    precondition(state.overlayNodeID == "root")
    let view = panel.contentView as! OverlayLayerView
    view.hover(nil); pump(0.3)
    let containers = layers(view.layer).filter { $0.bounds.width == 48 && $0.name != nil }
    let baseline = Dictionary(uniqueKeysWithValues: containers.map { ($0.name!, $0.position) })
    let scales = Dictionary(uniqueKeysWithValues: containers.map { ($0.name!, $0.value(forKeyPath: "transform.scale") as! CGFloat) })
    let leaf = containers.first { $0.name == "root/a/x" }!
    let sibling = containers.first { $0.name == "root/b" }!
    view.hover("root/a/x")
    precondition(leaf.animation(forKey: "transform.scale") is CASpringAnimation)
    precondition(abs(leaf.animation(forKey: "transform.scale")!.duration - 0.14) < 0.001)
    pump(0.22)
    for node in containers where ["root", "root/a", "root/a/x"].contains(node.name!) {
      precondition(node.position == baseline[node.name!], "Highlighted route drifted")
      precondition(abs((node.value(forKeyPath: "transform.scale") as! CGFloat) - scales[node.name!]! * 1.08) < 0.001)
      precondition(node.opacity == 1)
    }
    precondition(containers.allSatisfy { $0.position == baseline[$0.name!] })
    precondition(sibling.opacity == 0.45 && view.node(at: sibling.position) == "root/b")
    let edgePaths = layers(view.layer).compactMap { $0 as? CAShapeLayer }.filter { $0.name == nil && $0.path != nil }
    for id in ["root/b", "root/a/x", "root/b", "root/a/x"] {
      view.hover(id)
      precondition(containers.allSatisfy { $0.position == baseline[$0.name!] && $0.animation(forKey: "position") == nil },
                   "Sweeping the pointer moved a node")
      precondition(edgePaths.allSatisfy { $0.animation(forKey: "path") == nil }, "Hover redrew a trace")
    }
    precondition(view.node(at: leaf.position) == "root/a/x")
    view.hover(nil)
    precondition(abs(leaf.animation(forKey: "transform.scale")!.duration - 0.2) < 0.001)
    pump(0.25)
    for node in containers {
      precondition(node.position == baseline[node.name!])
      precondition((node.value(forKeyPath: "transform.scale") as! CGFloat) == scales[node.name!])
    }
    // Retarget midway through the return and navigate while still hovering.
    view.hover("root/a/x"); pump(0.04); view.hover("root/b"); pump(0.04)
    view.hover(nil); pump(0.03); view.hover("root/a/x"); pump(0.3)
    overlay.show(path: "a", screen: nil); pump(0.4)
    overlay.show(path: "", screen: nil); pump(0.4)
    view.hover(nil); pump(0.3)
    precondition(containers.allSatisfy { !isAnimating($0) })
    // With randomness zero, separate hover events have identical targets.
    view.fx.randomness = 0
    view.hover("root/a/x"); let deterministic = sibling.position
    view.hover(nil); view.hover("root/a/x")
    precondition(sibling.position == deterministic)
    pump(0.3)
    view.fx.hoverDuration = 0
    view.hover(nil)
    precondition(containers.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    view.fx.hover = false
    view.hover("root/a/x")
    precondition(sibling.position == baseline["root/b"] && sibling.opacity == 1)
    view.fx = OverlayFX()
    precondition(initial == Set(layers(panel.contentView?.layer).map(ObjectIdentifier.init)), "Effects rebuilt layers")
    precondition(layers(panel.contentView?.layer).compactMap { $0 as? CAShapeLayer }.allSatisfy(\.allowsEdgeAntialiasing))
    precondition(TypingOverlay.navigationURL(keys: ["a", " ", "&"])!.query!.contains("space"))
    overlay.hide(); pump(0.02); overlay.show(path: "b", screen: nil); pump()
    precondition(state.overlayVisible && panel.alphaValue == 1 && state.overlayNodeID == "root/b", "Stale hide won")
    // An invalid path must not invalidate the close completion.
    overlay.hide(); pump(0.02); overlay.show(path: "missing", screen: nil); pump()
    precondition(!state.overlayVisible && panel.alphaValue == 0 && panel.ignoresMouseEvents)
    pump(0.5)
    precondition(layers(panel.contentView?.layer).allSatisfy { ($0.animationKeys() ?? []).isEmpty }, "Hidden animation survived")
    precondition(backdrop.superlayer?.opacity == 0, "Backdrop failed to fade with scene")
    overlay.feedback(kind: "back", path: ""); pump()
    precondition(!state.overlayVisible, "Late feedback reopened a hidden overlay")
    overlay.show(path: "b", screen: nil); pump()
    overlay.hide(); overlay.feedback(kind: "back", path: ""); pump()
    precondition(!state.overlayVisible, "Feedback overwrote a pending hide")
    overlay.show(path: "b", screen: nil); pump()
    state.model = Node(id: "root", children: [Node(id: "root/new", key: "new")])
    pump()
    precondition(state.overlayVisible && state.overlayNodeID == "root", "Removed focus did not recover to root")
    let replacement = Set(layers(panel.contentView?.layer).map(ObjectIdentifier.init))
    precondition(replacement != initial, "Config failed to rebuild")
    precondition(layers(panel.contentView?.layer).contains { $0 === backdrop }, "Config rebuilt backdrop")
    state.model = nil; pump()
    precondition(!state.overlayVisible && panel.alphaValue == 0)
    // Volatile argument-domain defaults: exercise next-summon preferences
    // without touching the installed application's persistent defaults.
    let defaults = UserDefaults.standard
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    var preferences: [String: Any] = ["msFX.accentHex": "#A34EFF", "msFX.randomness": 0.0,
      "msFX.shake": 0.0, "msFX.glitch": 0.0, "msFX.curvedTraces": true, "msFX.curvature": 1.0]
    for flag in ["letterPop", "shockwave", "skullGlow", "miss", "back", "done", "hold", "close", "hover"] {
      preferences["msFX." + flag] = false
    }
    defaults.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
    state.model = root
    overlay.show(path: "", screen: nil); pump(0.5)
    let skull = layers(view.layer).compactMap { $0 as? CAShapeLayer }.first {
      $0.superlayer?.name == "root"
    }!
    precondition(skull.path!.boundingBoxOfPath.height == 56)
    precondition(skull.fillColor == OverlayFX.color(hex: "#A34EFF")!.cgColor && skull.shadowOpacity == 0)
    overlay.show(path: "a", screen: nil); pump(0.015)
    overlay.show(path: "a/x", screen: nil); pump(0.015)
    precondition(!layers(view.layer).contains { layer in
      (layer.animationKeys() ?? []).contains { $0.hasPrefix("jitter.") || $0 == "pop" }
    }, "Disabled motion still ran")
    precondition(!layers(view.layer).contains { ($0 as? CAShapeLayer)?.path?.boundingBoxOfPath.width == 180 && $0.animation(forKey: "opacity") != nil })
    preferences["msFX.accentHex"] = "#FFAA22"
    defaults.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
    precondition(skull.fillColor == OverlayFX.color(hex: "#A34EFF")!.cgColor)
    pump(0.3); overlay.hide(); pump(0.1)
    precondition(panel.alphaValue == 0 && view.ghostLayers.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    overlay.show(path: "", screen: nil); pump(0.3)
    precondition(skull.fillColor == OverlayFX.color(hex: "#FFAA22")!.cgColor, "Next summon did not apply palette")
    overlay.hide(); pump(0.1)
    print("PASS: 50 show/hide pairs + 50 paths coalesced; stable layer identities; full-screen/status level/Retina scale; interrupted close; invalid-path close; config removal/root fallback; missing config hides")
    panel.orderOut(nil)
  }
}
