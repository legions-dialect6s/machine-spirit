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
  private var shownAt: CFTimeInterval = 0
  private var hideRequested = false
  private var deferredHide: DispatchWorkItem?
  private var tempo = OverlayTempo()
  let placementPreview: PlacementPreview
  private var currentPath = ""
  private var revision = 0
  private var anchor = CGPoint.zero
  private var globalMouseMonitor: Any?
  private var localMouseMonitor: Any?
  private var feedbackQueue: [(String, String?, CFTimeInterval)] = []
  // Diagnostic A/B switch. Default selected by the measured show/idle test.
  private let keepOrdered = ProcessInfo.processInfo.environment["MS_OVERLAY_ORDER_OUT"] != "1"
  private let diagnostics = ProcessInfo.processInfo.environment["MS_OVERLAY_DIAGNOSTICS"] == "1"

  init(state: AppState, placementPreview: PlacementPreview = PlacementPreview()) {
    self.placementPreview = placementPreview
    self.state = state
    panel = PassivePanel(contentRect: NSScreen.main?.frame ?? .zero,
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.acceptsMouseMovedEvents = true
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
    panel.contentView = renderer
    renderer.onClick = { [weak self] id in self?.navigate(to: id) }
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

  func show(path: String, screen: String?, preview: Bool = false, held: Bool = false) {
    if held { placementPreview.leaveNavigation() }
    else if preview { placementPreview.arm(.mouse, path: "space/space", fx: shown ? renderer.fx : OverlayFX()) }
    else if !path.isEmpty, let id = state.route(atPath: path)?.last, let node = renderer.nodes[id],
            node.children.count == 1, let child = node.children.first, let key = child.key,
            let intent = PlacementIntent(action: child.action) {
      placementPreview.arm(intent, path: path + "/" + key, fx: shown ? renderer.fx : OverlayFX())
    } else { placementPreview.hide() }
    enqueue(Request(path: path, screen: screen, received: CACurrentMediaTime()))
  }

  func hide() {
    placementPreview.leaveNavigation()
    enqueue(Request(path: nil, received: CACurrentMediaTime()))
  }

  func feedback(kind: String, path: String?) {
    guard ["miss", "back", "done", "hold"].contains(kind),
      !hideRequested, pending.map({ $0.path != nil }) ?? shown else { return }
    // Feedback is an event, not a navigation snapshot. Preserve it separately
    // from the last-value mailbox, and resolve after the pending navigation.
    if kind == "back", let path { show(path: path, screen: nil) }
    feedbackQueue.append((kind, path, CACurrentMediaTime()))
    if feedbackQueue.count > 16 { feedbackQueue.removeFirst() }
    schedule()
  }

  static func navigationURL(keys: [String]) -> URL? {
    var url = URLComponents()
    url.scheme = "msleaderkey"; url.host = "navigate"
    url.queryItems = [URLQueryItem(name: "keys", value: keys.map { $0 == " " ? "space" : $0 }.joined(separator: ","))]
    return url.url
  }

  private func navigate(to id: String) {
    guard shown && !hideRequested else { return }
    func keys(_ node: Node, prefix: [String]) -> [String]? {
      let route = prefix + (node.key.map { [$0] } ?? [])
      if node.id == id { return route }
      for child in node.children { if let result = keys(child, prefix: route) { return result } }
      return nil
    }
    guard let root = state.model, let path = keys(root, prefix: []),
          let url = Self.navigationURL(keys: path) else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.open(url, configuration: configuration)
  }

  private func updateMouse() {
    guard shown && !hideRequested else { return }
    let point = renderer.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    let hit = renderer.node(at: point)
    panel.ignoresMouseEvents = hit == nil
    renderer.hover(hit)
  }

  private func startMouseMonitoring() {
    guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
    globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateMouse() }
    }
    localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
      self?.updateMouse(); return event
    }
  }

  private func stopMouseMonitoring() {
    if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    globalMouseMonitor = nil; localMouseMonitor = nil
    panel.ignoresMouseEvents = true
    renderer.hover(nil)
  }

  private func enqueue(_ request: Request) {
    // A show followed by hide in the same turn must still get its minimum dwell.
    if request.path == nil, pending?.path != nil {
      let hadScheduledDrain = scheduled
      applyPending()
      scheduled = hadScheduledDrain
    }
    pending = request
    schedule()
  }

  private func schedule() {
    guard !scheduled else { return }
    scheduled = true
    // One source per runloop turn; subsequent notifications overwrite its
    // mailbox. The minimum-visible hold owns one separate, cancellable deadline.
    RunLoop.main.perform(inModes: [.common]) { [weak self] in
      MainActor.assumeIsolated { self?.applyPending() }
    }
  }

  private func applyPending() {
    scheduled = false
    defer {
      let events = feedbackQueue; feedbackQueue.removeAll(keepingCapacity: true)
      if shown && !hideRequested {
        for (kind, path, received) in events {
          let target = path.flatMap { state.route(atPath: $0)?.last }
          // Ignore feedback for a route superseded in this runloop turn.
          if path == nil || target == renderer.focusID {
            if kind == "hold" { renderer.intensity = tempo.key(at: received) }
            renderer.feedback(kind)
          }
        }
      }
    }
    guard let request = pending else { return }
    pending = nil
    let started = CACurrentMediaTime()
    guard let path = request.path else {
      guard shown else { return }
      hideRequested = true
      stopMouseMonitoring()
      let remaining = 0.260 - (CACurrentMediaTime() - shownAt)
      if remaining > 0 {
        deferredHide?.cancel()
        let token = revision
        let work = DispatchWorkItem { [weak self] in
          guard let self, self.hideRequested, self.revision == token else { return }
          self.enqueue(Request(path: nil, received: CACurrentMediaTime()))
        }
        deferredHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
        return
      }
      deferredHide = nil
      revision += 1
      let revision = revision
      shown = false
      stopMouseMonitoring()
      state.overlayVisible = false
      state.sleepIfHidden()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      CATransaction.setCompletionBlock { [weak self] in
        MainActor.assumeIsolated {
          guard let self, !self.shown, self.revision == revision else { return }
          self.renderer.finishClose()
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
    deferredHide?.cancel(); deferredHide = nil
    hideRequested = false
    if shown && renderer.focusID == focusID {
      startMouseMonitoring(); updateMouse(); return
    }
    revision += 1
    let first = !shown
    let cold = first && renderer.isFullyHidden
    if first { shownAt = CACurrentMediaTime() }
    if cold {
      tempo = OverlayTempo()
      _ = tempo.key(at: request.received)
      let mouse = NSEvent.mouseLocation
      guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
        ?? Self.screen(matching: request.screen) else { return }
      if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
      renderer.fx = OverlayFX()
      renderer.safeRect = CGRect(x: screen.visibleFrame.minX - screen.frame.minX,
        y: screen.frame.maxY - screen.visibleFrame.maxY,
        width: screen.visibleFrame.width, height: screen.visibleFrame.height)
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
      renderer.beginOpen(focus: focusID, anchor: focusID == state.model?.id ? anchor : CGPoint(
        x: min(max(anchor.x, renderer.safeRect.minX + 29), renderer.safeRect.maxX - 29),
        y: min(max(anchor.y, renderer.safeRect.minY + 29), renderer.safeRect.maxY - 29)))
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
    if !first && changed && !back { renderer.intensity = tempo.key(at: request.received) }
    else if cold { renderer.intensity = 0 }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let navigationRevision = revision
    CATransaction.setCompletionBlock { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.shown, self.revision == navigationRevision else { return }
        self.updateMouse()
      }
    }
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
    startMouseMonitoring()
    updateMouse()
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
final class OverlayLayerView: NSView {
  private struct NodeLayers {
    let container: CALayer
    let icon: CALayer
    let label: CALayer
    let glyph: CATextLayer
    let skull: CAShapeLayer
    let disc: CALayer
    let iconPath: String?
  }
  private let scene = CALayer()
  private let backdrop = CAGradientLayer()
  private let edgeRoot = CALayer()
  private let nodeRoot = CALayer()
  private let marker = CAShapeLayer()
  private let rings = (0..<3).map { _ in CAShapeLayer() }
  private var ringIndex = 0
  private var displayed: [String: OverlayScene.Item] = [:]
  private var hovered: String?
  var onClick: ((String) -> Void)?
  var fx = OverlayFX() { didSet { applyPalette() } }
  private(set) var ghostLayers: [CAShapeLayer] = []
  private let ghosts = CALayer()
  private let slices = CALayer()
  private var sliceGlyphs: [CATextLayer] = []
  var intensity: Double = 0
  var safeRect = CGRect.zero { didSet { if oldValue != safeRect { cachedLayouts.removeAll() } } }
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
  private var mint: CGColor { fx.accentColor.cgColor }
  private let red = NSColor(calibratedRed: 1, green: 59 / 255, blue: 59 / 255, alpha: 1).cgColor
  private let blue = NSColor(calibratedRed: 59 / 255, green: 168 / 255, blue: 1, alpha: 1).cgColor
  override var isFlipped: Bool { true }
  var layerCount: Int {
    func count(_ l: CALayer) -> Int { 1 + (l.sublayers ?? []).reduce(0) { $0 + count($1) } }
    return layer.map(count) ?? 0
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    let root = CALayer()
    root.isGeometryFlipped = true
    layer = root
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    root.addSublayer(scene)
    backdrop.type = .radial
    backdrop.colors = [NSColor(calibratedWhite: 0, alpha: 0.45).cgColor,
                       NSColor(calibratedWhite: 0, alpha: 0).cgColor]
    backdrop.locations = [0, 1]
    backdrop.startPoint = CGPoint(x: 0.5, y: 0.5)
    backdrop.endPoint = CGPoint(x: 1, y: 1)
    scene.addSublayer(backdrop)
    scene.addSublayer(edgeRoot)
    scene.addSublayer(nodeRoot)
    marker.path = SkullMark.path(in: CGRect(x: -7, y: -7, width: 14, height: 14))
    marker.isHidden = true
    marker.fillRule = .evenOdd; marker.fillColor = mint
    marker.shadowColor = mint; marker.shadowRadius = 4; marker.shadowOpacity = 0.5
    marker.shadowOffset = .zero
    scene.addSublayer(marker)
    for ring in rings {
      ring.path = CGPath(ellipseIn: CGRect(x: -90, y: -90, width: 180, height: 180), transform: nil)
      ring.strokeColor = mint; ring.fillColor = nil; ring.lineWidth = 1
      ring.opacity = 0
      scene.addSublayer(ring)
    }
    scene.addSublayer(ghosts)
    for i in 0..<6 {
      let ghost = CAShapeLayer()
      ghost.bounds = CGRect(x: -28, y: -28, width: 56, height: 56)
      ghost.path = SkullMark.path(in: ghost.bounds)
      ghost.fillRule = .evenOdd; ghost.opacity = 0
      if i >= 3 {
        let mask = CALayer()
        mask.frame = CGRect(x: -32, y: -28 + CGFloat(i - 3) * 18, width: 64, height: 12)
        mask.backgroundColor = NSColor.white.cgColor
        ghost.mask = mask
      }
      ghosts.addSublayer(ghost); ghostLayers.append(ghost)
    }
    scene.addSublayer(slices)
    for i in 0..<3 {
      let glyph = text("", size: 16, color: mint)
      glyph.opacity = 0
      let mask = CALayer(); mask.backgroundColor = NSColor.white.cgColor
      mask.frame = CGRect(x: 0, y: CGFloat(i) * 8, width: 48, height: 5)
      glyph.mask = mask
      slices.addSublayer(glyph); sliceGlyphs.append(glyph)
    }
    applyPalette()
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
    visible.removeAll(); displayed.removeAll(); hovered = nil; cachedLayouts.removeAll(); focusID = nil
    func visit(_ node: Node, parent: String?) {
      nodes[node.id] = node
      let container = CALayer()
      container.name = node.id
      container.bounds = CGRect(x: -24, y: -24, width: 48, height: 48)
      container.opacity = 0
      let disc = CALayer()
      disc.frame = CGRect(x: -22, y: -22, width: 44, height: 44)
      disc.cornerRadius = 22
      disc.backgroundColor = NSColor(calibratedWhite: 0.035, alpha: 0.94).cgColor
      disc.borderColor = node.status.isInert ? NSColor.gray.cgColor : mint
      disc.borderWidth = 1.5
      disc.shadowColor = mint; disc.shadowOffset = .zero; disc.shadowRadius = 8
      disc.shadowOpacity = 0
      disc.shadowPath = CGPath(ellipseIn: disc.bounds, transform: nil)
      container.addSublayer(disc)
      let icon = CALayer()
      icon.frame = CGRect(x: -16, y: -16, width: 32, height: 32)
      icon.contentsGravity = .resizeAspect
      let iconPath = IconStore.iconPath(for: node)
      if let iconPath { icon.contents = IconStore.cgImage(forPath: iconPath, state: state) }
      container.addSublayer(icon)
      let keyLabel = node.key == "space" || node.key == " " ? "␣" : (node.key ?? "⇪")
      let glyph = text(keyLabel, size: 16, color: mint)
      glyph.frame = iconPath == nil ? CGRect(x: -20, y: -11, width: 40, height: 24)
        : CGRect(x: 9, y: 6, width: 23, height: 24)
      if iconPath != nil {
        glyph.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 0.98).cgColor
        glyph.cornerRadius = 6
      }
      container.addSublayer(glyph)
      let skull = CAShapeLayer()
      skull.path = SkullMark.path(in: CGRect(x: -28, y: -28, width: 56, height: 56))
      skull.fillRule = .evenOdd; skull.fillColor = mint
      skull.shadowColor = mint; skull.shadowRadius = 8; skull.shadowOpacity = 0.55
      skull.shadowOffset = .zero
      skull.isHidden = parent != nil || !fx.skull
      if parent == nil && fx.skull { disc.isHidden = true; glyph.isHidden = true; icon.isHidden = true }
      container.addSublayer(skull)
      let name = node.overlayLabel
      let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
      let width = max(48, ceil((name as NSString).size(withAttributes: [.font: font]).width) + 16)
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
      visuals[node.id] = NodeLayers(container: container, icon: icon, label: chip,
                                    glyph: glyph, skull: skull, disc: disc, iconPath: iconPath)
      if parent != nil {
        let edge = CAShapeLayer()
        // The layer is pooled; navigation replaces its straight/quadratic
        // geometry and strokeEnd reveals it in the render server.
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
      if layer is CAShapeLayer { layer.allowsEdgeAntialiasing = true }
      if let mask = layer.mask { visit(mask) }
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
                                   size: bounds.size, labelWidths: widths, safeRect: safeRect.isEmpty ? nil : safeRect)
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
                       duration: Double, delay: Double = 0, from: Any? = nil, springy: Bool = false) {
    let target = layer.value(forKeyPath: key)
    if from == nil, let old = target as? NSObject, let new = value as? NSObject,
       old.isEqual(new) { return }
    if duration <= 0 {
      layer.removeAnimation(forKey: key); layer.setValue(value, forKeyPath: key); return
    }
    let start = from ?? layer.presentation()?.value(forKeyPath: key) ?? target
    layer.setValue(value, forKeyPath: key)
    let animation: CABasicAnimation
    if springy {
      let spring = CASpringAnimation(keyPath: key)
      let frequency = 8 / duration
      spring.mass = 1; spring.stiffness = frequency * frequency; spring.damping = 1.5 * frequency
      animation = spring
    } else { animation = CABasicAnimation(keyPath: key) }
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
    marker.isHidden = true
    // Invisible old paths can be reset without a visual discontinuity. On an
    // interrupted close we skip this path entirely and preserve presentation.
    for id in visible {
      visuals[id]?.container.removeAllAnimations()
      visuals[id]?.container.opacity = 0
      edges[id]?.removeAllAnimations()
      edges[id]?.opacity = 0
    }
    if let v = visuals[focus] {
      if nodes[focus]?.key == nil {
        v.skull.isHidden = !fx.skull; v.disc.isHidden = fx.skull; v.glyph.isHidden = fx.skull
        v.skull.shadowOpacity = fx.skullGlow ? 0.55 : 0
      }
      v.container.position = anchor
      v.container.opacity = 1
      v.label.opacity = 0
      animate(v.container, "transform.scale", to: CGFloat(1), duration: fx.openingDuration,
              from: nodes[focus]?.key == nil && fx.skull ? CGFloat(1) : CGFloat(0.7))
    }
    visible = [focus]
    focusID = focus
    backdrop.removeAllAnimations()
    backdrop.position = anchor
    backdrop.bounds = CGRect(x: 0, y: 0, width: 104, height: 104)
    animate(scene, "opacity", to: Float(1), duration: fx.openingDuration)
    summon()
  }

  func show(_ items: [String: OverlayScene.Item], focus: String, anchor: CGPoint,
            first: Bool, back: Bool, splash: Bool) {
    let duration = back ? (fx.back ? fx.backDuration : 0) : fx.openingDuration
    hover(nil)
    displayed = items
    marker.isHidden = !fx.skull || nodes[focus]?.key == nil
    marker.shadowOpacity = fx.skullGlow ? 0.5 : 0
    marker.position = CGPoint(x: (items[focus]?.center.x ?? anchor.x) + 14,
                              y: (items[focus]?.center.y ?? anchor.y) - 14)
    for (id, visual) in visuals where nodes[id]?.key == nil {
      visual.skull.isHidden = !fx.skull
      visual.disc.isHidden = fx.skull; visual.glyph.isHidden = fx.skull
      visual.skull.shadowOpacity = fx.skullGlow ? 0.55 : 0
    }
    animate(scene, "opacity", to: Float(1), duration: fx.openingDuration)
    // Cover the complete neighborhood, including label extents, with a soft
    // margin beyond its furthest grandchild. A square keeps the dim circular.
    let center = items[focus]?.center ?? anchor
    let radius = OverlayScene.backdropRadius(items: items, focus: center, labelWidths: widths)
    animate(backdrop, "position", to: NSValue(point: center), duration: duration)
    animate(backdrop, "bounds", to: NSValue(rect: CGRect(x: 0, y: 0,
      width: radius * 2, height: radius * 2)), duration: duration)
    for id in visible.subtracting(items.keys) {
      guard let v = visuals[id] else { continue }
      animate(v.container, "opacity", to: Float(0), duration: fx.back ? fx.backDuration : 0)
      if back { animate(v.container, "position", to: NSValue(point: anchor), duration: fx.back ? fx.backDuration : 0) }
      if let edge = edges[id] { animate(edge, "opacity", to: Float(0), duration: fx.back ? fx.backDuration : 0) }
    }
    for (id, item) in items {
      guard let v = visuals[id] else { continue }
      if v.container.animation(forKey: "closeSpin") != nil {
        let angle = v.container.presentation()?.value(forKeyPath: "transform.rotation.z") ?? 0
        v.container.removeAnimation(forKey: "closeSpin")
        animate(v.container, "transform.rotation.z", to: 0, duration: duration, from: angle)
      }
      let fresh = !visible.contains(id) || (first && (scene.presentation()?.opacity ?? 0) < 0.01)
      let origin = item.parent.flatMap { items[$0]?.center } ?? anchor
      if fresh {
        v.container.removeAllAnimations()
        v.container.opacity = item.opacity
        v.container.setValue(item.scale, forKeyPath: "transform.scale")
        if id == focus {
          v.container.position = item.center
          animate(v.container, "transform.scale", to: item.scale, duration: duration,
                  from: nodes[id]?.key == nil && fx.skull ? item.scale : CGFloat(0.7))
        } else {
          animate(v.container, "position", to: NSValue(point: item.center), duration: duration,
                  delay: item.delay, from: NSValue(point: origin))
        }
      } else {
        animate(v.container, "position", to: NSValue(point: item.center), duration: duration, delay: item.delay)
        animate(v.container, "opacity", to: item.opacity, duration: duration)
        animate(v.container, "transform.scale", to: item.scale, duration: duration)
      }
      if fresh || (splash && id == focus) { arrivalJitter(v.container) }
      v.label.opacity = item.label ? 1 : 0
      v.container.zPosition = id == focus ? 2 : (item.scale == 1 ? 1 : 0)
      if let edge = edges[id], let parent = item.parent, let source = items[parent]?.center {
        let path = tracePath(from: source, to: item.center)
        if fresh { edge.removeAllAnimations(); edge.path = path }
        else { animate(edge, "path", to: path, duration: duration) }
        animate(edge, "opacity", to: item.opacity * 0.55, duration: duration)
        animate(edge, "strokeEnd", to: CGFloat(1), duration: duration, delay: item.delay,
                from: fresh ? CGFloat(0) : nil)
      } else if let edge = edges[id] { animate(edge, "opacity", to: Float(0), duration: duration) }
    }
    if splash, let v = visuals[focus] {
      if fx.letterPop { spring(v.glyph, from: 2.4, duration: fx.popDuration) }
      if fx.shockwave { shockwave(at: items[focus]?.center ?? anchor) }
      react(v, at: items[focus]?.center ?? anchor)
    }
    visible = Set(items.keys)
    focusID = focus
  }

  func fadeOut() {
    let duration = fx.close ? fx.closeDuration : 0
    let ghostDuration = fx.close && fx.skull && fx.glitch > 0 && duration > 0 ? 0.2 : 0
    if ghostDuration > 0 { ghostExit(duration: ghostDuration) }
    let root = displayed.first(where: { nodes[$0.key]?.key == nil })?.value.center
      ?? displayed[focusID ?? ""]?.center ?? .zero
    for id in visible {
      guard let v = visuals[id] else { continue }
      if fx.close && duration > 0 {
        animate(v.container, "position", to: NSValue(point: root), duration: duration)
        animate(v.container, "transform.scale", to: CGFloat(0.15), duration: duration)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0; spin.toValue = 0.12; spin.duration = duration
        v.container.add(spin, forKey: "closeSpin")
      }
      if let edge = edges[id] { animate(edge, "strokeEnd", to: CGFloat(0), duration: duration) }
      if nodes[id]?.key == nil && fx.close { pulse(v.skull, strength: 1.15, duration: duration) }
    }
    for ring in rings { ring.removeAllAnimations() }
    if ghostDuration > 0 {
      let fade = CAKeyframeAnimation(keyPath: "opacity")
      let current = scene.presentation()?.opacity ?? scene.opacity
      fade.values = [current, current, 0]; fade.keyTimes = [0, 0.9, 1]
      fade.duration = max(duration, ghostDuration)
      scene.opacity = 0; scene.add(fade, forKey: "opacity")
    } else { animate(scene, "opacity", to: Float(0), duration: duration) }
  }

  func finishClose() {
    func stop(_ layer: CALayer) {
      layer.removeAllAnimations()
      if let mask = layer.mask { stop(mask) }
      layer.sublayers?.forEach(stop)
    }
    stop(scene)
  }

  private func spring(_ layer: CALayer, from: CGFloat, duration: Double) {
    guard duration > 0 else { return }
    let animation = CASpringAnimation(keyPath: "transform.scale")
    animation.fromValue = from; animation.toValue = 1
    animation.mass = 1; animation.stiffness = 850; animation.damping = 29
    animation.duration = duration
    layer.add(animation, forKey: "pop")
  }

  private func pulse(_ layer: CALayer, strength: CGFloat, duration: Double, twice: Bool = false) {
    guard duration > 0 else { return }
    let animation = CAKeyframeAnimation(keyPath: "transform.scale")
    animation.values = twice ? [1, strength, 1, strength, 1] : [1, strength, 1]
    animation.duration = duration
    layer.add(animation, forKey: "feedbackPulse")
  }

  private func flash(_ layer: CALayer, key: String, color: CGColor, duration: Double) {
    guard duration > 0 else { return }
    let animation = CAKeyframeAnimation(keyPath: key)
    animation.values = [color, color, layer.value(forKeyPath: key) ?? color]
    animation.keyTimes = [0, 0.55, 1]
    animation.duration = duration
    layer.add(animation, forKey: "feedbackColor.\(key)")
  }

  private func shockwave(at point: CGPoint) {
    guard fx.shockwaveDuration > 0 else { return }
    for index in 0..<(intensity > 0.75 ? 2 : 1) {
      let ring = rings[ringIndex]; ringIndex = (ringIndex + 1) % rings.count
      ring.removeAllAnimations(); ring.position = point
      ring.lineWidth = index == 0 ? 1.5 : 0.65
      let delay = index == 0 ? 0.0 : 0.055
      animate(ring, "transform.scale", to: CGFloat(0.6 + intensity * 0.65),
              duration: fx.shockwaveDuration, delay: delay, from: CGFloat(0.02))
      animate(ring, "opacity", to: Float(0), duration: fx.shockwaveDuration, delay: delay,
              from: Float((0.18 + intensity * 0.30) * (index == 0 ? 1 : 0.55)))
    }
  }

  private func applyPalette() {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    marker.fillColor = mint; marker.shadowColor = mint
    for ring in rings { ring.strokeColor = mint }
    for (id, v) in visuals {
      v.disc.borderColor = nodes[id]?.status.isInert == true ? NSColor.gray.cgColor : mint
      v.disc.shadowColor = mint
      v.glyph.foregroundColor = mint; v.skull.fillColor = mint; v.skull.shadowColor = mint
    }
    for edge in edges.values { edge.strokeColor = mint }
    for (i, ghost) in ghostLayers.enumerated() {
      ghost.fillColor = i % 3 == 0 ? mint : (i % 3 == 1
        ? NSColor(srgbRed: 0.25, green: 0.9, blue: 1, alpha: 1).cgColor
        : NSColor(srgbRed: 0.95, green: 0.3, blue: 0.8, alpha: 1).cgColor)
    }
    for glyph in sliceGlyphs { glyph.foregroundColor = mint }
    CATransaction.commit()
  }

  func summon() {
    guard fx.skull, fx.openingDuration > 0,
          let root = visuals.first(where: { nodes[$0.key]?.key == nil })?.value else { return }
    let animation = CAKeyframeAnimation(keyPath: "transform.scale")
    animation.values = [0.55, 1.25, 1.0]; animation.keyTimes = [0, 0.58, 1]
    animation.timingFunctions = [ease, CAMediaTimingFunction(name: .easeInEaseOut)]
    animation.duration = max(0.22, fx.openingDuration)
    root.skull.add(animation, forKey: "summon")
    if fx.skullGlow {
      animate(root.skull, "shadowRadius", to: CGFloat(8), duration: animation.duration, from: CGFloat(22))
      animate(root.skull, "shadowOpacity", to: Float(0.55), duration: animation.duration, from: Float(1))
    }
  }

  private func stepped(_ layer: CALayer, key: String, values: [Any], duration: Double) {
    let animation = CAKeyframeAnimation(keyPath: key)
    animation.values = values; animation.calculationMode = .discrete; animation.duration = duration
    layer.add(animation, forKey: "jitter." + key)
  }

  private func arrivalJitter(_ layer: CALayer) {
    guard fx.randomness > 0, fx.openingDuration > 0 else { return }
    let x = Double.random(in: -3...3) * fx.randomness
    let y = Double.random(in: -3...3) * fx.randomness
    let angle = Double.random(in: -0.09...0.09) * fx.randomness
    stepped(layer, key: "transform.translation.x", values: [x, -x * 0.4, 0], duration: 0.1)
    stepped(layer, key: "transform.translation.y", values: [y, -y * 0.4, 0], duration: 0.1)
    stepped(layer, key: "transform.rotation.z", values: [angle, -angle * 0.4, 0], duration: 0.1)
  }

  private func react(_ visual: NodeLayers, at point: CGPoint) {
    if intensity > 0 && fx.shake > 0 {
      let angle = Double.random(in: 0...(2 * .pi))
      let amplitude = 6 * intensity * fx.shake
      for (key, offset) in [("transform.translation.x", cos(angle) * amplitude),
                            ("transform.translation.y", sin(angle) * amplitude)] {
        stepped(scene, key: key, values: [offset, -offset * 0.7, offset * 0.3, 0], duration: 0.12)
      }
    }
    guard intensity > 0.5, fx.glitch > 0 else { return }
    slices.position = point
    for glyph in sliceGlyphs {
      glyph.removeAllAnimations(); glyph.frame = visual.glyph.frame; glyph.string = visual.glyph.string
      glyph.fontSize = visual.glyph.fontSize
      let offset = Double.random(in: -8...8) * intensity * fx.glitch
      stepped(glyph, key: "transform.translation.x", values: [offset, -offset, offset * 0.4, 0], duration: 0.12)
      animate(glyph, "opacity", to: Float(0), duration: 0.12, from: Float(fx.glitch))
    }
  }

  private func ghostExit(duration: Double) {
    guard let root = visuals.first(where: { nodes[$0.key]?.key == nil })?.value,
          !root.skull.isHidden else { return }
    let presentation = root.container.presentation() ?? root.container
    ghosts.position = presentation.position; ghosts.transform = presentation.transform
    for (i, ghost) in ghostLayers.enumerated() {
      ghost.removeAllAnimations()
      let direction = i % 2 == 0 ? 1.0 : -1.0
      let offset = direction * Double.random(in: 3...9) * fx.glitch
      if i < 3 {
        animate(ghost, "transform.translation.x", to: offset, duration: duration, from: 0)
        animate(ghost, "transform.translation.y", to: Double(i - 1) * 4, duration: duration, from: 0)
      } else {
        stepped(ghost, key: "transform.translation.x", values: [0, offset, -offset, offset * 1.4, 0], duration: duration)
      }
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = Float((i == 0 ? 0.65 : 0.32) * fx.glitch) * presentation.opacity
      fade.toValue = Float(0); fade.duration = duration
      ghost.opacity = 0; ghost.add(fade, forKey: "opacity")
    }
  }

  func feedback(_ kind: String) {
    guard let focusID, let focus = visuals[focusID] else { return }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let letter: CALayer = nodes[focusID]?.key == nil && fx.skull ? focus.skull : focus.glyph
    switch kind {
    case "miss" where fx.miss:
      for id in visible {
        guard let v = visuals[id] else { continue }
        flash(v.disc, key: "borderColor", color: red, duration: fx.missDuration)
        flash(v.disc, key: "backgroundColor", color: red.copy(alpha: 0.65)!, duration: fx.missDuration)
        flash(v.glyph, key: "foregroundColor", color: red, duration: fx.missDuration)
        flash(v.skull, key: "fillColor", color: red, duration: fx.missDuration)
        flash(v.skull, key: "shadowColor", color: red, duration: fx.missDuration)
        flash(v.label, key: "backgroundColor", color: red.copy(alpha: 0.65)!, duration: fx.missDuration)
        if let edge = edges[id] { flash(edge, key: "strokeColor", color: red, duration: fx.missDuration) }
      }
      flash(marker, key: "fillColor", color: red, duration: fx.missDuration)
      pulse(letter, strength: 1.35, duration: fx.missDuration, twice: true)
    case "done" where fx.done:
      for id in route(to: focusID) {
        if let edge = edges[id] {
          flash(edge, key: "strokeColor", color: blue, duration: fx.doneDuration)
          animate(edge, "opacity", to: edge.opacity, duration: fx.doneDuration, from: Float(1))
        }
        if let v = visuals[id] {
          flash(v.disc, key: "borderColor", color: blue, duration: fx.doneDuration)
          flash(v.glyph, key: "foregroundColor", color: blue, duration: fx.doneDuration)
          flash(v.skull, key: "fillColor", color: blue, duration: fx.doneDuration)
          flash(v.skull, key: "shadowColor", color: blue, duration: fx.doneDuration)
        }
      }
      flash(marker, key: "fillColor", color: blue, duration: fx.doneDuration)
      pulse(letter, strength: 1.15, duration: fx.doneDuration)
    case "back" where fx.back && nodes[focusID]?.key == nil:
      pulse(letter, strength: 1.15, duration: fx.popDuration)
      if fx.skullGlow { animate(focus.skull, "shadowOpacity", to: Float(0.55), duration: fx.popDuration, from: Float(1)) }
    case "hold" where fx.hold:
      pulse(letter, strength: 1.12, duration: fx.holdDuration)
      if let point = displayed[focusID]?.center {
        if fx.shockwave { shockwave(at: point) }
        react(focus, at: point)
      }
    default: break
    }
  }

  private func route(to id: String) -> Set<String> {
    var route: Set<String> = []; var current: String? = id
    while let next = current, route.insert(next).inserted { current = displayed[next]?.parent }
    return route
  }

  private func tracePath(from source: CGPoint, to target: CGPoint) -> CGPath {
    func align(_ point: CGPoint) -> CGPoint {
      scale == 1 ? CGPoint(x: floor(point.x) + 0.5, y: floor(point.y) + 0.5) : point
    }
    let start = align(source), end = align(target)
    let path = CGMutablePath(); path.move(to: start)
    if fx.curvedTraces {
      let dx = end.x - start.x, dy = end.y - start.y
      path.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2 - dy * (0.2 * fx.curvature),
                                                y: (start.y + end.y) / 2 + dx * (0.2 * fx.curvature)))
    } else { path.addLine(to: end) }
    return path
  }

  func node(at point: CGPoint) -> String? {
    // Hit-test the layout, including labels, independently of the hover scale.
    visible.sorted { (visuals[$0]?.container.zPosition ?? 0) > (visuals[$1]?.container.zPosition ?? 0) }.first { id in
      guard let v = visuals[id], let item = displayed[id], item.scale > 0 else { return false }
      let local = CGPoint(x: (point.x - item.center.x) / item.scale,
                          y: (point.y - item.center.y) / item.scale)
      return CGRect(x: -24, y: -24, width: 48, height: 48).contains(local)
        || (item.label && v.label.frame.contains(local))
    }
  }

  func hover(_ id: String?) {
    let id = fx.hover ? id.flatMap { displayed[$0] == nil ? nil : $0 } : nil
    guard hovered != id else { return }
    hovered = id
    let active = id.map { route(to: $0).union(focusID.map { route(to: $0) } ?? []) } ?? []
    let duration = fx.hoverDuration * (id == nil ? 10.0 / 7.0 : 1)
    CATransaction.begin(); CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    for (node, item) in displayed {
      let highlighted = active.contains(node)
      let dimmed = id != nil && !highlighted
      if let v = visuals[node] {
        animate(v.container, "transform.scale", to: item.scale * (highlighted ? 1.08 : 1),
                duration: duration, springy: highlighted)
        animate(v.container, "opacity", to: highlighted ? Float(1) : item.opacity * (dimmed ? 0.45 : 1), duration: duration)
        if !v.disc.isHidden {
          animate(v.disc, "shadowOpacity", to: Float(highlighted && fx.skullGlow ? 0.65 : 0), duration: duration)
        }
        if nodes[node]?.key == nil && !v.skull.isHidden {
          animate(v.skull, "shadowOpacity", to: Float(fx.skullGlow ? (highlighted ? 0.85 : 0.55) : 0), duration: duration)
          animate(v.skull, "shadowRadius", to: CGFloat(highlighted ? 12 : 8), duration: duration)
        }
      }
      if item.parent != nil, let edge = edges[node] {
        animate(edge, "lineWidth", to: CGFloat(highlighted ? 1.5 : 1), duration: duration)
        animate(edge, "opacity", to: highlighted ? Float(0.95) : item.opacity * (dimmed ? 0.25 : 0.55), duration: duration)
      }
    }
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
    if let id = node(at: convert(event.locationInWindow, from: nil)) { onClick?(id) }
  }
}
