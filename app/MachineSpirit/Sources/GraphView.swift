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
  private let growthDuration = 1.5

  var body: some View {
    GeometryReader { geometry in
      let model = state.displayModel
      // Semantic zoom: shallow rings when far out; deeper rings bloom and
      // the layout reorganizes as you come closer.
      let drawModel = model.map { prune($0, depth: 0, maxDepth: visibleDepth) }
      let layout = drawModel.map { RadialLayout.layout(root: $0) }

      // 20fps: the sway is slow (≈1.7 rad/s) and reads identically, and an
      // always-running canvas must respect the heat lesson (SESSION-LOG).
      TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
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
      sway = 0.8 + exp(-calm * 2.0) * 5.0
      self.maxRadius = maxRadius
      self.growthDuration = growthDuration
    }

    var growing: Bool { elapsed < growthDuration }

    /// 0…1 reveal of an element at the given radius — the growth runs from
    /// the center to the rim.
    func reveal(atRadius radius: Double, lag: Double = 0) -> Double {
      guard growing else { return 1 }
      let delay = radius / maxRadius * (growthDuration * 0.55) + lag
      return min(max((elapsed - delay) / 0.4, 0), 1)
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
  /// its children glow; everything else recedes.
  private func glowSet(in model: Node) -> Set<String>? {
    guard let id = state.selectedNodeID else { return nil }
    var lit = Set(AppState.ancestorIDs(of: id))
    lit.insert(id)
    if let node = model.node(withID: id) {
      for child in node.children { lit.insert(child.id) }
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

  private func drawEdges(
    _ root: Node, layout: GraphLayout, transform: CanvasTransform,
    glow: Set<String>?, pulse: Pulse, in context: inout GraphicsContext
  ) {
    // Traces batch per (category, depth) so width can taper with depth
    // while strokes stay few.
    var litPaths: [Int: Path] = [:]
    var dimPaths: [Int: Path] = [:]
    var inertPaths: [Int: Path] = [:]

    walk(root) { node in
      guard let from = layout.positions[node.id] else { return }
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
        if child.status.isInert {
          inertPaths[depth, default: Path()].addPath(segment)
        } else if lit {
          litPaths[depth, default: Path()].addPath(segment)
        } else {
          dimPaths[depth, default: Path()].addPath(segment)
        }
      }
    }

    context.drawLayer { layer in
      layer.addFilter(.shadow(color: Theme.phosphor.opacity(0.5), radius: 3))
      let dimOpacity = glow == nil ? 0.7 : 0.25
      for (depth, path) in dimPaths {
        layer.stroke(
          path, with: .color(Theme.phosphorDim.opacity(dimOpacity)),
          lineWidth: taper(depth))
      }
      for (depth, path) in inertPaths {
        layer.stroke(
          path, with: .color(Theme.ash.opacity(glow == nil ? 0.28 : 0.14)),
          lineWidth: taper(depth) * 0.9)
      }
      for (depth, path) in litPaths {
        layer.stroke(
          path, with: .color(Theme.phosphor.opacity(0.95)),
          lineWidth: taper(depth) * 1.5)
      }
    }
  }

  /// Trace width thins as the run leaves the center — heavier arteries at
  /// the first ring, hairlines at the rim.
  private func taper(_ depth: Int) -> CGFloat {
    max(0.55, 2.1 - CGFloat(depth) * 0.38)
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
    let wobble = sin(pulse.seconds * 1.7 + phase) * pulse.sway

    // From the center, the trace is a near-straight spoke with a soft lean.
    guard r1 > 5, r2 > r1 + 8 else {
      let mid = CGPoint(
        x: (a.x + b.x) / 2 - (b.y - a.y) * 0.03 + wobble * 0.4,
        y: (a.y + b.y) / 2 + (b.x - a.x) * 0.03 + wobble * 0.4)
      path.move(to: a)
      path.addQuadCurve(to: b, control: mid)
      return path
    }

    let theta1 = atan2(from.y, from.x)
    let theta2 = atan2(to.y, to.x)
    var deltaTheta = theta2 - theta1
    while deltaTheta > .pi { deltaTheta -= 2 * .pi }
    while deltaTheta < -.pi { deltaTheta += 2 * .pi }

    // Sibling-staggered junction ring, swaying a little.
    let fraction = siblings <= 1 ? 0.5 : 0.34 + 0.32 * Double(index) / Double(siblings - 1)
    let junction = r1 + (r2 - r1) * fraction + wobble / max(Double(transform.scale), 0.001)

    let control1 = transform.apply(
      x: junction * cos(theta1 + deltaTheta * 0.3),
      y: junction * sin(theta1 + deltaTheta * 0.3))
    let control2 = transform.apply(
      x: junction * cos(theta1 + deltaTheta * 0.7),
      y: junction * sin(theta1 + deltaTheta * 0.7))

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
      let radius = (node.isDual ? dualRadius : nodeRadius) * (birth < 1 ? birth : 1)

      let primary: Color = inert ? Theme.ash : (node.isDual ? Theme.magenta : Theme.phosphor)

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

      // Key glyph, constant size — the address of the node.
      context.draw(
        Text(node.key ?? "·")
          .font(.system(size: node.isDual ? 14 : 12, design: .monospaced).weight(.bold))
          .foregroundStyle(glyphColor(for: node).opacity(recede ? 0.35 : Double(birth))),
        at: center)

      // Name/summary appears once there is room for it (and always along
      // the lit path).
      if zoom > 0.5 || selected || (lit && glow != nil) {
        context.draw(
          Text(node.displayName)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(
              recede
                ? Theme.ash.opacity(0.25)
                : (inert ? Theme.ash.opacity(0.6) : Theme.ash.opacity(Double(birth)))),
          at: CGPoint(x: center.x, y: center.y + radius + 9))
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
