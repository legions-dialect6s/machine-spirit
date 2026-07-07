import AppKit
import MachineSpiritKit
import SwiftUI

/// The node graph: the config projected 360° from the center (one center
/// per leader key; more middles are a Phase-2 concern).
///
/// The glyph language:
///   action  = filled core
///   group   = halo ring
///   both    = ring AND core, both lit — group+action duality (magenta)
///   inert   = ashen ghost
///
/// The board is alive: traces grow out of the center on boot/refresh, sway
/// faintly at rest like vines in water, stir when the viewport moves, and
/// taper as they run outward. Nodes hold a constant screen size; zoom moves
/// the space between them. Selection lights the path from the center.
struct GraphView: View {
  @Environment(AppState.self) private var state

  @GestureState private var dragDelta: CGSize = .zero
  @GestureState private var pinchFactor: CGFloat = 1

  private let nodeRadius: CGFloat = 13
  private let dualRadius: CGFloat = 18
  private let growthDuration = 0.85

  var body: some View {
    GeometryReader { geometry in
      let model = state.displayModel
      // Semantic zoom: shallow rings when far out; deeper rings bloom and
      // the layout reorganizes as you come closer.
      let drawModel = model.map { prune($0, depth: 0, maxDepth: visibleDepth) }
      let layout = drawModel.map { RadialLayout.layout(root: $0) }

      // 30fps while anything moves; a calm, settled board PAUSES its clock
      // — no idle jitter, no idle heat (SESSION-LOG lesson). disturb() is
      // observed, so the first movement wakes the clock immediately.
      let stillness = Date().timeIntervalSince(state.lastDisturbance)
      let settled = Date().timeIntervalSince(state.bootStamp) > growthDuration + 0.6
      TimelineView(
        .animation(minimumInterval: 1.0 / 30.0, paused: settled && stillness > 3.5)
      ) { timeline in
        Canvas { context, size in
          guard let drawModel, let layout else { return }
          let transform = canvasTransform(viewport: size)
          let glow = glowSet(in: drawModel)
          let pulse = Pulse(
            now: timeline.date,
            bootStamp: state.bootStamp,
            lastDisturbance: state.lastDisturbance,
            maxRadius: max(layout.width / 2, 1),
            growthDuration: growthDuration)
          drawEdges(
            drawModel, layout: layout, transform: transform, glow: glow, pulse: pulse,
            in: &context)
          drawNodes(
            drawModel, layout: layout, transform: transform, glow: glow, pulse: pulse,
            in: &context)
        }
      }
      .background(Theme.ground)
      .onGeometryChange(for: CGRect.self) { proxy in
        proxy.frame(in: .global)
      } action: { frame in
        state.graphFrame = frame
      }
      .contentShape(Rectangle())
      .gesture(panGesture)
      .simultaneousGesture(zoomGesture)
      .onTapGesture { location in
        guard let layout else { return }
        let transform = canvasTransform(viewport: geometry.size)
        if let hitID = hitTest(location, in: layout, transform: transform) {
          state.selectedNodeID = hitID
          state.revealSelectionInTree()
        } else {
          // Dead space clears the walk — typing starts from the root again.
          state.selectedNodeID = nil
        }
      }
      .onChange(of: state.selectedNodeID) {
        // The walk: glide the selection to center, both hands on the keys.
        // Centering targets the FULL layout — deep selections zoom to a
        // band where they are visible, and there pruned == full.
        guard let id = state.selectedNodeID, let model,
          let position = RadialLayout.layout(root: model).positions[id]
        else { return }
        let zoom = max(state.zoom, 1.0)
        state.glide(
          toPan: CGSize(width: -position.x * zoom, height: -position.y * zoom),
          zoom: zoom)
      }
    }
    .clipped()
    .overlay(alignment: .topTrailing) { zoomControls }
  }

  // MARK: - Time: growth on boot, sway at rest, stir on movement

  private struct Pulse {
    let seconds: Double  // continuous clock for the sway
    let elapsed: Double  // since boot/refresh
    let sway: Double  // amplitude in points
    let maxRadius: Double
    let growthDuration: Double

    init(
      now: Date, bootStamp: Date, lastDisturbance: Date, maxRadius: Double,
      growthDuration: Double
    ) {
      seconds = now.timeIntervalSinceReferenceDate
      elapsed = now.timeIntervalSince(bootStamp)
      let calm = max(0, now.timeIntervalSince(lastDisturbance))
      // No baseline: perfectly still at rest (the clock pauses anyway);
      // movement wakes a smooth, decaying sway.
      sway = exp(-calm * 1.3) * 8.0
      self.maxRadius = maxRadius
      self.growthDuration = growthDuration
    }

    var growing: Bool { elapsed < growthDuration }

    /// 0…1 reveal of an element at the given radius — the growth runs from
    /// the center to the rim.
    func reveal(atRadius radius: Double, lag: Double = 0) -> Double {
      guard growing else { return 1 }
      let delay = radius / maxRadius * (growthDuration * 0.5) + lag
      return min(max((elapsed - delay) / 0.25, 0), 1)
    }
  }

  // MARK: - Viewport math (screen = world * zoom + center + pan)

  private var effectiveZoom: CGFloat { state.zoom * pinchFactor }

  private struct CanvasTransform {
    var scale: CGFloat
    var offset: CGSize

    func apply(_ position: GraphLayout.Position) -> CGPoint {
      CGPoint(
        x: position.x * scale + offset.width,
        y: position.y * scale + offset.height)
    }

    func apply(x: Double, y: Double) -> CGPoint {
      CGPoint(x: x * scale + offset.width, y: y * scale + offset.height)
    }

    func unapply(_ point: CGPoint) -> GraphLayout.Position {
      .init(
        x: (point.x - offset.width) / scale,
        y: (point.y - offset.height) / scale)
    }
  }

  private func canvasTransform(viewport: CGSize) -> CanvasTransform {
    CanvasTransform(
      scale: effectiveZoom,
      offset: CGSize(
        width: viewport.width / 2 + state.pan.width + dragDelta.width,
        height: viewport.height / 2 + state.pan.height + dragDelta.height))
  }

  private var panGesture: some Gesture {
    DragGesture(minimumDistance: 3)
      .updating($dragDelta) { value, delta, _ in delta = value.translation }
      .onEnded { value in
        state.cancelGlide()
        state.pan.width += value.translation.width
        state.pan.height += value.translation.height
        state.disturb()
      }
  }

  private var zoomGesture: some Gesture {
    MagnifyGesture()
      .updating($pinchFactor) { value, factor, _ in factor = value.magnification }
      .onEnded { value in
        state.cancelGlide()
        state.zoom = min(max(state.zoom * value.magnification, state.minZoom), state.maxZoom)
        state.disturb()
      }
  }

  private func hitTest(
    _ point: CGPoint, in layout: GraphLayout, transform: CanvasTransform
  ) -> String? {
    let world = transform.unapply(point)
    let reach = Double(dualRadius + 8) / Double(transform.scale)
    var best: (id: String, distance: Double)?
    for (id, position) in layout.positions {
      let distance = hypot(position.x - world.x, position.y - world.y)
      if distance <= reach, distance < (best?.distance ?? .infinity) {
        best = (id, distance)
      }
    }
    return best?.id
  }

  /// Depth band per zoom: the reorganize-as-you-zoom mechanic.
  private var visibleDepth: Int {
    switch effectiveZoom {
    case ..<0.22: return 1
    case ..<0.45: return 2
    case ..<0.8: return 3
    default: return .max
    }
  }

  /// The lit path: with a selection, the trace from the center to it plus
  /// its ENTIRE subtree glow; everything else recedes.
  private func glowSet(in model: Node) -> Set<String>? {
    guard let id = state.selectedNodeID else { return nil }
    var lit = Set(AppState.ancestorIDs(of: id))
    lit.insert(id)
    if let node = model.node(withID: id) {
      func igniteDescendants(_ node: Node) {
        for child in node.children {
          lit.insert(child.id)
          igniteDescendants(child)
        }
      }
      igniteDescendants(node)
    }
    return lit
  }

  /// Display-only copy cut to the band; nodes that lost children carry a
  /// marker so they can whisper that more waits below.
  private func prune(_ node: Node, depth: Int, maxDepth: Int) -> Node {
    var pruned = node
    if depth >= maxDepth, !node.children.isEmpty {
      pruned.children = []
      pruned.extras["__ms_pruned"] = .bool(true)
    } else {
      pruned.children = node.children.map { prune($0, depth: depth + 1, maxDepth: maxDepth) }
    }
    return pruned
  }

  // MARK: - Controls

  private var zoomControls: some View {
    @Bindable var state = state
    return HStack(spacing: 6) {
      Text("−").foregroundStyle(Theme.phosphorDim)
      Slider(
        value: Binding(
          get: { log(state.zoom) },
          set: {
            state.cancelGlide()
            state.zoom = min(max(exp($0), state.minZoom), state.maxZoom)
            state.disturb()
          }
        ),
        in: log(state.minZoom)...log(state.maxZoom)
      )
      .frame(width: 140)
      .controlSize(.mini)
      .tint(Theme.phosphorDim)
      Text("+").foregroundStyle(Theme.phosphorDim)
    }
    .font(.system(size: 12, design: .monospaced).weight(.bold))
    .padding(8)
    .opacity(0.85)
  }

  // MARK: - Drawing

  /// A node's identity color in the graph — app nodes take their icon's
  /// dominant tint; everything else follows the Theme palette.
  private func color(of node: Node) -> Color {
    if case .application(let path) = node.action, node.status.isInert == false {
      return IconStore.tint(forPath: (path as NSString).expandingTildeInPath)
    }
    return Theme.nodeColor(for: node)
  }

  private func drawEdges(
    _ root: Node, layout: GraphLayout, transform: CanvasTransform,
    glow: Set<String>?, pulse: Pulse, in context: inout GraphicsContext
  ) {
    context.drawLayer { layer in
      layer.addFilter(.shadow(color: Theme.phosphor.opacity(0.45), radius: 3))
      walk(root) { node in
        guard let from = layout.positions[node.id] else { return }
        let parentColor = node.id == "root" ? Theme.phosphorDim : color(of: node)
        let siblingCount = node.children.count
        for (index, child) in node.children.enumerated() {
          guard let to = layout.positions[child.id] else { continue }
          var segment = trace(
            from: from, to: to, childID: child.id, index: index,
            siblings: siblingCount, pulse: pulse, transform: transform)

          let childRadius = hypot(to.x, to.y)
          let reveal = pulse.reveal(atRadius: childRadius)
          if reveal <= 0 { continue }
          if reveal < 1 { segment = segment.trimmedPath(from: 0, to: reveal) }

          let depth = child.id.split(separator: "/").count - 1
          let lit =
            glow == nil
            ? false
            : (glow!.contains(child.id) && (glow!.contains(node.id) || node.id == "root"))

          // Trace color runs parent → child: the wiring itself tells you
          // what kind of thing it feeds.
          let childColor = color(of: child)
          let alpha: Double
          let width: CGFloat
          if child.status.isInert {
            alpha = glow == nil ? 0.25 : 0.12
            width = taper(depth) * 0.9
          } else if lit {
            alpha = 0.95
            width = taper(depth) * 1.5
          } else {
            alpha = glow == nil ? 0.6 : 0.2
            width = taper(depth)
          }
          layer.stroke(
            segment,
            with: .linearGradient(
              Gradient(colors: [
                parentColor.opacity(alpha * 0.8), childColor.opacity(alpha),
              ]),
              startPoint: transform.apply(from),
              endPoint: transform.apply(to)),
            lineWidth: width)
        }
      }
    }
  }

  /// Trace width thins as the run leaves the center — but gently, and ever
  /// more gently the further out it goes (geometric decay, floored).
  private func taper(_ depth: Int) -> CGFloat {
    max(0.85, 2.0 * pow(0.88, CGFloat(max(depth - 1, 0))))
  }

  /// One trace, polar-routed without corners: a cubic whose control points
  /// ride an intermediate junction ring, staggered per sibling so parallel
  /// runs layer instead of stacking. The junction breathes with the sway —
  /// vines in water, wired like a circuit.
  private func trace(
    from: GraphLayout.Position, to: GraphLayout.Position,
    childID: String, index: Int, siblings: Int,
    pulse: Pulse, transform: CanvasTransform
  ) -> Path {
    var path = Path()
    let r1 = hypot(from.x, from.y)
    let r2 = hypot(to.x, to.y)
    let a = transform.apply(from)
    let b = transform.apply(to)

    let byteSum = childID.utf8.reduce(0) { $0 &+ Int($1) }
    let phase = Double(byteSum % 628) / 100.0
    // Sway lives in SCREEN space so it stays visible at every zoom; two
    // slightly detuned sines so the drift never looks metronomic.
    let wobble = sin(pulse.seconds * 1.4 + phase) * pulse.sway
    let wobble2 = sin(pulse.seconds * 0.9 + phase * 2.3) * pulse.sway * 0.7

    // From the center, the trace is a near-straight spoke with a soft lean.
    guard r1 > 5, r2 > r1 + 8 else {
      let mid = CGPoint(
        x: (a.x + b.x) / 2 - (b.y - a.y) * 0.03 + wobble,
        y: (a.y + b.y) / 2 + (b.x - a.x) * 0.03 + wobble2)
      path.move(to: a)
      path.addQuadCurve(to: b, control: mid)
      return path
    }

    let theta1 = atan2(from.y, from.x)
    let theta2 = atan2(to.y, to.x)
    var deltaTheta = theta2 - theta1
    while deltaTheta > .pi { deltaTheta -= 2 * .pi }
    while deltaTheta < -.pi { deltaTheta += 2 * .pi }

    // Sibling-staggered junction ring; the sway rides the control points in
    // screen space so the vines visibly breathe at any zoom.
    let fraction = siblings <= 1 ? 0.5 : 0.34 + 0.32 * Double(index) / Double(siblings - 1)
    let junction = r1 + (r2 - r1) * fraction

    var control1 = transform.apply(
      x: junction * cos(theta1 + deltaTheta * 0.3),
      y: junction * sin(theta1 + deltaTheta * 0.3))
    var control2 = transform.apply(
      x: junction * cos(theta1 + deltaTheta * 0.7),
      y: junction * sin(theta1 + deltaTheta * 0.7))
    control1.x += wobble
    control1.y += wobble2
    control2.x -= wobble2
    control2.y += wobble

    path.move(to: a)
    path.addCurve(to: b, control1: control1, control2: control2)
    return path
  }

  private func drawNodes(
    _ root: Node, layout: GraphLayout, transform: CanvasTransform,
    glow: Set<String>?, pulse: Pulse, in context: inout GraphicsContext
  ) {
    let zoom = transform.scale

    walk(root) { node in
      guard let position = layout.positions[node.id] else { return }

      // Growth: a node fades in just after its trace arrives.
      let birth = pulse.reveal(atRadius: hypot(position.x, position.y), lag: 0.12)
      if birth <= 0 { return }

      let center = transform.apply(position)
      let inert = node.status.isInert
      let selected = node.id == state.selectedNodeID
      let lit = glow?.contains(node.id) ?? true
      let recede = glow != nil && !lit
      // A pruned node still opens onward — the band just hides it for now.
      let hidesMore = node.extras["__ms_pruned"] != nil
      // Constant screen size: the space zooms, the nodes do not.
      let isRoot = node.id == "root"
      let baseRadius = isRoot ? dualRadius : (node.isDual ? dualRadius : nodeRadius)
      let radius = baseRadius * (birth < 1 ? birth : 1)

      let primary: Color = inert ? Theme.ash : color(of: node)

      context.drawLayer { layer in
        layer.opacity = Double(birth) * (recede ? 0.35 : 1)
        if !inert && !recede {
          layer.addFilter(
            .shadow(
              color: primary.opacity(selected ? 0.95 : (lit && glow != nil ? 0.8 : 0.45)),
              radius: selected ? 9 : (lit && glow != nil ? 6 : 4)))
        }

        let discRect = CGRect(
          x: center.x - radius, y: center.y - radius,
          width: radius * 2, height: radius * 2)
        layer.fill(Circle().path(in: discRect), with: .color(Theme.ground))

        // App / folder / command nodes carry their real icon, clipped into
        // the disc and dimmed so the key glyph stays the address.
        if birth > 0.8, !inert, let iconPath = IconStore.iconPath(for: node) {
          layer.drawLayer { iconLayer in
            iconLayer.clip(to: Circle().path(in: discRect.insetBy(dx: 1.5, dy: 1.5)))
            iconLayer.opacity = recede ? 0.25 : 0.55
            iconLayer.draw(
              IconStore.icon(forPath: iconPath),
              in: discRect.insetBy(dx: 1.5, dy: 1.5))
          }
        }

        // Halo ring — this node opens onward (a group, or a band-pruned
        // branch whose depths wait below).
        if node.isGroup || hidesMore {
          layer.stroke(
            Circle().path(in: discRect),
            with: .color(primary.opacity(inert ? 0.5 : 1)),
            lineWidth: selected ? 2.5 : 1.5)
        }
        if hidesMore {
          // A faint outer whisper: more is folded beneath this ring.
          let hintRect = discRect.insetBy(dx: -4, dy: -4)
          layer.stroke(
            Circle().path(in: hintRect),
            with: .color(primary.opacity(0.25)), lineWidth: 1)
        }

        // Filled core — this node acts.
        if node.action != nil {
          let coreRadius = radius * 0.55
          let coreRect = CGRect(
            x: center.x - coreRadius, y: center.y - coreRadius,
            width: coreRadius * 2, height: coreRadius * 2)
          layer.fill(
            Circle().path(in: coreRect),
            with: .color(primary.opacity(inert ? 0.35 : (node.isGroup ? 0.85 : 0.7))))
          if !node.isGroup, selected {
            layer.stroke(
              Circle().path(in: discRect),
              with: .color(primary.opacity(0.8)), lineWidth: 1.5)
          }
        }
      }

      guard birth > 0.6 else { return }

      // Key glyph, constant size — the address of the node. The root wears
      // the leader key itself.
      let glyphBack = CGRect(
        x: center.x - 7, y: center.y - 7.5, width: 14, height: 15)
      context.fill(
        RoundedRectangle(cornerRadius: 4).path(in: glyphBack),
        with: .color(Theme.ground.opacity(recede ? 0.4 : 0.75)))
      context.draw(
        Text(isRoot ? "⇪" : (node.key ?? "·"))
          .font(
            .system(size: isRoot ? 17 : (node.isDual ? 14 : 12), design: .monospaced)
              .weight(.bold))
          .foregroundStyle(glyphColor(for: node).opacity(recede ? 0.35 : Double(birth))),
        at: center)

      // Name/summary radiates OUTWARD along the node's own angle — labels
      // grow into the empty space between spokes instead of onto the board.
      if !isRoot, zoom > 0.5 || selected || (lit && glow != nil) {
        let angle = atan2(position.y, position.x)
        let anchor: UnitPoint =
          cos(angle) > 0.35 ? .leading : (cos(angle) < -0.35 ? .trailing : .center)
        let labelDistance = Double(radius) + 6
        var labelPoint = CGPoint(
          x: center.x + CGFloat(cos(angle) * labelDistance),
          y: center.y + CGFloat(sin(angle) * labelDistance))
        if anchor == .center {
          labelPoint.y += sin(angle) > 0 ? 8 : -8
        }

        let label = context.resolve(
          Text(node.displayName)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(
              recede
                ? Theme.ash.opacity(0.25)
                : (inert
                  ? Theme.ash.opacity(0.6)
                  : Color(white: 0.64).opacity(Double(birth)))))
        let size = label.measure(in: CGSize(width: 320, height: 40))
        var pill = CGRect(origin: labelPoint, size: size)
        switch anchor {
        case .leading: pill.origin.y -= size.height / 2
        case .trailing: pill.origin.x -= size.width; pill.origin.y -= size.height / 2
        default: pill.origin.x -= size.width / 2; pill.origin.y -= size.height / 2
        }
        if !recede {
          context.fill(
            RoundedRectangle(cornerRadius: 4).path(in: pill.insetBy(dx: -4, dy: -1.5)),
            with: .color(Theme.ground.opacity(0.72)))
        }
        context.draw(label, in: pill)
      }
    }
  }

  private func glyphColor(for node: Node) -> Color {
    if node.status.isInert { return Theme.ash }
    if node.action != nil { return Color.white.opacity(0.92) }
    return node.isDual ? Theme.magenta : Theme.phosphor
  }

  private func walk(_ node: Node, _ visit: (Node) -> Void) {
    visit(node)
    for child in node.children { walk(child, visit) }
  }
}
