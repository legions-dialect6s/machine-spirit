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
    let state = AppState()
    state.model = root
    let overlay = TypingOverlay(state: state)
    let panel = NSApp.windows.first { $0 is NSPanel }!
    func pump(_ seconds: Double = 0.24) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func layers(_ layer: CALayer?) -> [CALayer] {
      guard let layer else { return [] }
      return [layer] + (layer.sublayers ?? []).flatMap { layers($0) }
    }
    let initial = Set(layers(panel.contentView?.layer).map(ObjectIdentifier.init))
    let gradients = layers(panel.contentView?.layer).compactMap { $0 as? CAGradientLayer }
    precondition(gradients.count == 1 && gradients[0].type == .radial)
    let backdrop = gradients[0]
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
    precondition(panel.frame == panel.screen!.frame && panel.ignoresMouseEvents)
    precondition(panel.level.rawValue > Int(CGWindowLevelForKey(.statusWindow)))
    precondition(layers(panel.contentView?.layer).allSatisfy { $0.contentsScale == panel.screen!.backingScaleFactor })
    overlay.hide(); pump(0.02); overlay.show(path: "b", screen: nil); pump()
    precondition(state.overlayVisible && panel.alphaValue == 1 && state.overlayNodeID == "root/b", "Stale hide won")
    // An invalid path must not invalidate the close completion.
    overlay.hide(); pump(0.02); overlay.show(path: "missing", screen: nil); pump()
    precondition(!state.overlayVisible && panel.alphaValue == 0)
    precondition(backdrop.superlayer?.opacity == 0, "Backdrop failed to fade with scene")
    overlay.show(path: "b", screen: nil); pump()
    state.model = Node(id: "root", children: [Node(id: "root/new", key: "new")])
    pump()
    precondition(state.overlayVisible && state.overlayNodeID == "root", "Removed focus did not recover to root")
    let replacement = Set(layers(panel.contentView?.layer).map(ObjectIdentifier.init))
    precondition(replacement != initial, "Config failed to rebuild")
    precondition(layers(panel.contentView?.layer).contains { $0 === backdrop }, "Config rebuilt backdrop")
    state.model = nil; pump()
    precondition(!state.overlayVisible && panel.alphaValue == 0)
    print("PASS: 50 show/hide pairs + 50 paths coalesced; stable layer identities; full-screen/status level/Retina scale; interrupted close; invalid-path close; config removal/root fallback; missing config hides")
    panel.orderOut(nil)
  }
}
