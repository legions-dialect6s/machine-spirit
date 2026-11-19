import AppKit
import QuartzCore
import MachineSpiritKit

@MainActor
final class TypingOverlay {
  private struct Request {
    var path: String? // nil means hidden
    var screen: String?
    var received: CFTimeInterval
  }
  private let state: AppState
  private let panel: PassivePanel
  private let renderer = OverlayLayerView()
  private var pending: Request?
  private var scheduled = false
  private var shown = false
  private var currentPath = ""
  private var revision = 0
  private var anchor = CGPoint.zero
  // Diagnostic A/B switch. Default selected by the measured show/idle test.
  private let keepOrdered = ProcessInfo.processInfo.environment["MS_OVERLAY_ORDER_OUT"] != "1"
  private let diagnostics = ProcessInfo.processInfo.environment["MS_OVERLAY_DIAGNOSTICS"] == "1"

  init(state: AppState) {
    self.state = state
    panel = PassivePanel(contentRect: NSScreen.main?.frame ?? .zero,
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
    panel.contentView = renderer
    renderer.rebuild(state.model, state: state)
    renderer.setScale(NSScreen.main?.backingScaleFactor ?? 2)
    panel.alphaValue = 0
    if keepOrdered { panel.orderFrontRegardless() }
    // Serialize the prebuilt hidden tree during startup, not on the first
    // Caps Lock. Otherwise the first explicit flush pays for every layer.
    CATransaction.flush()
    state.overlayConfigChanged = { [weak self] in
      guard let self else { return }
      self.renderer.rebuild(self.state.model, state: self.state)
      if self.shown {
        if self.state.model == nil { self.hide() }
        else {
          let path = self.state.route(atPath: self.currentPath) == nil ? "" : self.currentPath
          self.show(path: path, screen: nil)
        }
      }
    }
    IconStore.onCGImageAvailable = { [weak self] path, image in
      self?.renderer.updateIcon(path: path, image: image)
    }
  }

  func show(path: String, screen: String?) {
    enqueue(Request(path: path, screen: screen, received: CACurrentMediaTime()))
  }

  func hide() { enqueue(Request(path: nil, received: CACurrentMediaTime())) }

  private func enqueue(_ request: Request) {
    pending = request
    guard !scheduled else { return }
    scheduled = true
    // One source per runloop turn; subsequent notifications overwrite its
    // mailbox. No animation tasks, delayed work items, or growing input queue.
    RunLoop.main.perform(inModes: [.common]) { [weak self] in
      MainActor.assumeIsolated { self?.applyPending() }
    }
  }

  private func applyPending() {
    scheduled = false
    guard let request = pending else { return }
    pending = nil
    let started = CACurrentMediaTime()
    guard let path = request.path else {
      guard shown else { return }
      revision += 1
      let revision = revision
      shown = false
      state.overlayVisible = false
      state.sleepIfHidden()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      CATransaction.setCompletionBlock { [weak self] in
        MainActor.assumeIsolated {
          guard let self, !self.shown, self.revision == revision else { return }
          self.panel.alphaValue = 0
          if !self.keepOrdered { self.panel.orderOut(nil) }
        }
      }
      renderer.fadeOut()
      CATransaction.commit()
      return
    }
    guard let route = state.route(atPath: path), let focusID = route.last,
          let focus = renderer.nodes[focusID] else { return }
    if shown && renderer.focusID == focusID { return }
    revision += 1
    let first = !shown
    if first {
      let mouse = NSEvent.mouseLocation
      guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
        ?? Self.screen(matching: request.screen) else { return }
      if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
      renderer.setScale(screen.backingScaleFactor)
      renderer.refreshRate = Float(screen.maximumFramesPerSecond)
      let spawn = screen.frame.contains(mouse) ? mouse : CGPoint(x: screen.frame.midX, y: screen.frame.midY)
      anchor = CGPoint(x: spawn.x - screen.frame.minX, y: screen.frame.maxY - spawn.y)
    }
    var firstCommit: CFTimeInterval?
    if first && renderer.isFullyHidden {
      // Send immediate visual feedback before the cold, dense-root collision
      // pass. This is real rendered content, not an empty timing transaction.
      // Subsequent navigation uses a single commit and presentation values.
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      renderer.beginOpen(focus: focusID, anchor: anchor)
      panel.alphaValue = 1
      if !keepOrdered { panel.orderFrontRegardless() }
      CATransaction.commit()
      firstCommit = CACurrentMediaTime()
      CATransaction.flush()
    }
    let ancestors = route.dropLast().compactMap { renderer.nodes[$0] }
    let layoutStarted = CACurrentMediaTime()
    let layout = renderer.layout(focus: focus, ancestors: ancestors, anchor: anchor)
    let layoutMS = (CACurrentMediaTime() - layoutStarted) * 1000
    let back = !first && route.count < currentPath.split(separator: "/").count + 1
    let changed = renderer.focusID != focusID
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    renderer.show(layout, focus: focusID, anchor: anchor, first: first,
                  back: back, splash: !first && changed && !back)
    CATransaction.commit()
    let committed = CACurrentMediaTime()
    if first && firstCommit == nil {
      panel.alphaValue = 1
      if !keepOrdered { panel.orderFrontRegardless() }
    }
    shown = true
    currentPath = path.hasPrefix("root/") ? String(path.dropFirst(5)) : path
    state.overlayNodeID = focusID
    state.overlayVisible = true
    if diagnostics {
      print(String(format: "overlay commit receipt=%.3fms full=%.3fms apply=%.3fms layout=%.3fms path=%@ nodes=%d layers=%d ordered=%@",
        ((firstCommit ?? committed) - request.received) * 1000,
        (committed - request.received) * 1000,
        (CACurrentMediaTime() - started) * 1000, layoutMS, path, layout.count,
        renderer.layerCount, keepOrdered ? "yes" : "no"))
      fflush(stdout)
    }
  }

  private static func screen(matching text: String?) -> NSScreen? {
    if let values = text?.split(separator: ",").compactMap({ Double($0) }), values.count == 4 {
      if let match = NSScreen.screens.first(where: {
        zip([$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height], values)
          .allSatisfy { abs($0.0 - $0.1) < 1 }
      }) { return match }
    }
    return NSScreen.main
  }
}

private final class PassivePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Layer-hosting, not layer-backed drawing. CA owns every animated frame;
/// the app changes properties only on navigation/config/icon/display events.
@MainActor
private final class OverlayLayerView: NSView {
  private struct NodeLayers {
    let container: CALayer
    let icon: CALayer
    let label: CALayer
    let splash: CATextLayer
    let iconPath: String?
  }
  private let scene = CALayer()
  private let edgeRoot = CALayer()
  private let nodeRoot = CALayer()
  private var visuals: [String: NodeLayers] = [:]
  private var edges: [String: CAShapeLayer] = [:]
  private(set) var nodes: [String: Node] = [:]
  private(set) var focusID: String?
  private var widths: [String: CGFloat] = [:]
  private var visible: Set<String> = []
  private var scale: CGFloat = 0
  private var cachedLayouts: [String: [String: OverlayScene.Item]] = [:]
  private var layoutAnchor = CGPoint(x: -1, y: -1)
  private var layoutSize = CGSize.zero
  var refreshRate: Float = 120
  private let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
  private let mint = NSColor(calibratedRed: 0.29, green: 1, blue: 0.55, alpha: 1).cgColor
  override var isFlipped: Bool { true }
  var layerCount: Int { 4 + visuals.count * 7 + edges.count }

  override init(frame: NSRect) {
    super.init(frame: frame)
    let root = CALayer()
    root.isGeometryFlipped = true
    layer = root
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    root.addSublayer(scene)
    scene.addSublayer(edgeRoot)
    scene.addSublayer(nodeRoot)
    scene.opacity = 0
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    if let screen = window?.screen {
      setScale(screen.backingScaleFactor)
      refreshRate = Float(screen.maximumFramesPerSecond)
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

  func rebuild(_ model: Node?, state: AppState) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    nodeRoot.sublayers = nil
    edgeRoot.sublayers = nil
    visuals.removeAll(); edges.removeAll(); nodes.removeAll(); widths.removeAll()
    visible.removeAll(); cachedLayouts.removeAll(); focusID = nil
    func visit(_ node: Node, parent: String?) {
      nodes[node.id] = node
      let container = CALayer()
      container.bounds = CGRect(x: -24, y: -24, width: 48, height: 48)
      container.opacity = 0
      let disc = CALayer()
      disc.frame = CGRect(x: -22, y: -22, width: 44, height: 44)
      disc.cornerRadius = 22
      disc.backgroundColor = NSColor(calibratedWhite: 0.035, alpha: 0.94).cgColor
      disc.borderColor = node.status.isInert ? NSColor.gray.cgColor : mint
      disc.borderWidth = 1.5
      container.addSublayer(disc)
      let icon = CALayer()
      icon.frame = CGRect(x: -16, y: -16, width: 32, height: 32)
      icon.contentsGravity = .resizeAspect
      let iconPath = IconStore.iconPath(for: node)
      if let iconPath { icon.contents = IconStore.cgImage(forPath: iconPath, state: state) }
      container.addSublayer(icon)
      let glyph = text(node.key ?? "⇪", size: 16, color: mint)
      glyph.frame = iconPath == nil ? CGRect(x: -20, y: -11, width: 40, height: 24)
        : CGRect(x: 9, y: 6, width: 23, height: 24)
      if iconPath != nil {
        glyph.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 0.98).cgColor
        glyph.cornerRadius = 6
      }
      container.addSublayer(glyph)
      let name = node.displayName
      let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
      let width = min(146, max(48, ceil((name as NSString).size(withAttributes: [.font: font]).width) + 16))
      widths[node.id] = width
      let chip = CALayer()
      chip.frame = CGRect(x: -width / 2, y: 28, width: width, height: 22)
      chip.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 0.88).cgColor
      chip.cornerRadius = 6
      let label = text(name, size: 12, color: NSColor.white.cgColor)
      label.frame = CGRect(x: 6, y: 3, width: width - 12, height: 17)
      label.truncationMode = .end
      chip.addSublayer(label)
      container.addSublayer(chip)
      nodeRoot.addSublayer(container)
      // A glyph per node is prebuilt too; navigation never replaces strings.
      let splash = text(node.key ?? "⇪", size: 18, color: mint)
      splash.bounds = CGRect(x: 0, y: 0, width: 44, height: 28)
      splash.opacity = 0
      nodeRoot.addSublayer(splash)
      visuals[node.id] = NodeLayers(container: container, icon: icon, label: chip,
                                    splash: splash, iconPath: iconPath)
      if parent != nil {
        let edge = CAShapeLayer()
        // Unit segment transformed/rotated into place. No path allocation on
        // keystrokes; strokeEnd reveals the cable in the render server.
        let path = CGMutablePath(); path.move(to: .zero); path.addLine(to: CGPoint(x: 1, y: 0))
        edge.path = path
        edge.strokeColor = mint
        edge.lineWidth = 1
        edge.fillColor = nil
        edge.opacity = 0
        edgeRoot.addSublayer(edge)
        edges[node.id] = edge
      }
      node.children.forEach { visit($0, parent: node.id) }
    }
    if let model { visit(model, parent: nil) }
    let previousScale = scale; scale = 0; setScale(max(1, previousScale))
    CATransaction.commit()
  }

  func setScale(_ value: CGFloat) {
    guard scale != value else { return }
    scale = value
    CATransaction.begin(); CATransaction.setDisableActions(true)
    func visit(_ layer: CALayer) {
      layer.contentsScale = value
      layer.sublayers?.forEach(visit)
    }
    if let layer { visit(layer) }
    CATransaction.commit()
  }

  func updateIcon(path: String, image: CGImage) {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    for visual in visuals.values where visual.iconPath == path { visual.icon.contents = image }
    CATransaction.commit()
  }

  func layout(focus: Node, ancestors: [Node], anchor: CGPoint) -> [String: OverlayScene.Item] {
    if anchor != layoutAnchor || bounds.size != layoutSize {
      cachedLayouts.removeAll(); layoutAnchor = anchor; layoutSize = bounds.size
    }
    if let cached = cachedLayouts[focus.id] { return cached }
    let value = OverlayScene.layout(focus: focus, ancestors: ancestors, anchor: anchor,
                                   size: bounds.size, labelWidths: widths)
    cachedLayouts[focus.id] = value
    return value
  }

  private func text(_ string: String, size: CGFloat, color: CGColor) -> CATextLayer {
    let layer = CATextLayer()
    layer.string = string
    layer.font = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
    layer.fontSize = size
    layer.alignmentMode = .center
    layer.foregroundColor = color
    return layer
  }

  /// Every interruption samples the render server before replacing the keyed
  /// animation. The model always contains the final state, with no callbacks
  /// that can resurrect a stale path.
  private func animate(_ layer: CALayer, _ key: String, to value: Any,
                       duration: Double, delay: Double = 0, from: Any? = nil) {
    let target = layer.value(forKeyPath: key)
    if from == nil, let old = target as? NSObject, let new = value as? NSObject,
       old.isEqual(new) { return }
    let start = from ?? layer.presentation()?.value(forKeyPath: key) ?? target
    layer.setValue(value, forKeyPath: key)
    let animation = CABasicAnimation(keyPath: key)
    animation.fromValue = start
    animation.toValue = value
    animation.duration = duration
    animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, refreshRate), maximum: refreshRate, preferred: refreshRate)
    animation.timingFunction = ease
    animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
    animation.fillMode = .backwards
    layer.add(animation, forKey: key)
  }

  var isFullyHidden: Bool { (scene.presentation()?.opacity ?? scene.opacity) < 0.001 }

  func beginOpen(focus: String, anchor: CGPoint) {
    // Invisible old paths can be reset without a visual discontinuity. On an
    // interrupted close we skip this path entirely and preserve presentation.
    for id in visible {
      visuals[id]?.container.removeAllAnimations()
      visuals[id]?.container.opacity = 0
      visuals[id]?.splash.removeAllAnimations()
      visuals[id]?.splash.opacity = 0
      edges[id]?.removeAllAnimations()
      edges[id]?.opacity = 0
    }
    if let v = visuals[focus] {
      v.container.position = anchor
      v.container.opacity = 1
      v.label.opacity = 0
      animate(v.container, "transform.scale", to: CGFloat(1), duration: 0.14, from: CGFloat(0.7))
    }
    visible = [focus]
    focusID = focus
    animate(scene, "opacity", to: Float(1), duration: 0.12)
  }

  func show(_ items: [String: OverlayScene.Item], focus: String, anchor: CGPoint,
            first: Bool, back: Bool, splash: Bool) {
    let duration = back ? 0.09 : 0.14
    animate(scene, "opacity", to: Float(1), duration: 0.12)
    for id in visible.subtracting(items.keys) {
      guard let v = visuals[id] else { continue }
      animate(v.container, "opacity", to: Float(0), duration: 0.09)
      if back { animate(v.container, "position", to: NSValue(point: anchor), duration: 0.09) }
      if let edge = edges[id] { animate(edge, "opacity", to: Float(0), duration: 0.09) }
    }
    for (id, item) in items {
      guard let v = visuals[id] else { continue }
      let fresh = !visible.contains(id) || (first && (scene.presentation()?.opacity ?? 0) < 0.01)
      let origin = item.parent.flatMap { items[$0]?.center } ?? anchor
      if fresh {
        v.container.removeAllAnimations()
        v.container.opacity = item.opacity
        v.container.setValue(item.scale, forKeyPath: "transform.scale")
        if id == focus {
          v.container.position = item.center
          animate(v.container, "transform.scale", to: item.scale, duration: duration, from: CGFloat(0.7))
        } else {
          animate(v.container, "position", to: NSValue(point: item.center), duration: duration,
                  delay: item.delay, from: NSValue(point: origin))
        }
      } else {
        animate(v.container, "position", to: NSValue(point: item.center), duration: duration, delay: item.delay)
        animate(v.container, "opacity", to: item.opacity, duration: duration)
        animate(v.container, "transform.scale", to: item.scale, duration: duration)
      }
      v.label.opacity = item.label ? 1 : 0
      v.container.zPosition = id == focus ? 2 : (item.scale == 1 ? 1 : 0)
      if let edge = edges[id], let parent = item.parent, let source = items[parent]?.center {
        let dx = item.center.x - source.x, dy = item.center.y - source.y
        let transform = CATransform3DMakeAffineTransform(CGAffineTransform(a: dx, b: dy,
                                                                          c: -sin(atan2(dy, dx)), d: cos(atan2(dy, dx)), tx: 0, ty: 0))
        if fresh {
          edge.removeAllAnimations()
          edge.position = source
          edge.transform = transform
          edge.opacity = item.opacity * 0.55
        } else {
          animate(edge, "position", to: NSValue(point: source), duration: duration)
          animate(edge, "transform", to: NSValue(caTransform3D: transform), duration: duration)
        }
        animate(edge, "opacity", to: item.opacity * 0.55, duration: duration)
        animate(edge, "strokeEnd", to: CGFloat(1), duration: duration, delay: item.delay,
                from: fresh ? CGFloat(0) : nil)
      } else if let edge = edges[id] { animate(edge, "opacity", to: Float(0), duration: duration) }
    }
    // Terminate any previous splash with a presentation-value fade.
    if let old = focusID, old != focus, let v = visuals[old] {
      animate(v.splash, "opacity", to: Float(0), duration: 0.06)
    }
    if splash, let v = visuals[focus] {
      v.splash.position = anchor
      animate(v.splash, "transform.scale", to: CGFloat(1), duration: 0.14, from: CGFloat(2.6))
      animate(v.splash, "opacity", to: Float(0), duration: 0.14, from: Float(1))
    }
    visible = Set(items.keys)
    focusID = focus
  }

  func fadeOut() { animate(scene, "opacity", to: Float(0), duration: 0.08) }
}
