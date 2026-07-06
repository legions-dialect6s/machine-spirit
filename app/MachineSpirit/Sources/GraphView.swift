import AppKit
import MachineSpiritKit
import SwiftUI

/// The node graph: the same model as the directory, projected 360° from the
/// center (one center per leader key; more middles are a Phase-2 concern).
///
/// The glyph language:
///   action  = filled core
///   group   = halo ring
///   both    = ring AND core, both lit — group+action duality
///   inert   = ashen ghost
///
/// Nodes hold a constant screen size; zoom moves the space between them.
/// Scroll pans, ⌘-scroll zooms, pinch zooms, letters walk, selection glides
/// to center.
struct GraphView: View {
  @Environment(AppState.self) private var state

  @GestureState private var dragDelta: CGSize = .zero
  @GestureState private var pinchFactor: CGFloat = 1

  private let nodeRadius: CGFloat = 13
  private let dualRadius: CGFloat = 18

  var body: some View {
    GeometryReader { geometry in
      let model = state.displayModel
      // Semantic zoom: zoomed out shows the shallow rings; zooming in makes
      // deeper rings bloom and the layout reorganize around them. Nodes
      // keep a constant screen size throughout.
      let drawModel = model.map { prune($0, depth: 0, maxDepth: visibleDepth) }
      let layout = drawModel.map { RadialLayout.layout(root: $0) }

      Canvas { context, size in
        guard let drawModel, let layout else { return }
        let transform = canvasTransform(viewport: size)
        let glow = glowSet(in: drawModel)
        drawEdges(drawModel, layout: layout, transform: transform, glow: glow, in: &context)
        drawNodes(drawModel, layout: layout, transform: transform, glow: glow, in: &context)
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
        guard let model, let layout else { return }
        let transform = canvasTransform(viewport: geometry.size)
        _ = model
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
  /// its children glow; everything else recedes. No selection → nil, and
  /// the whole board sits at normal brightness.
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
      }
  }

  private var zoomGesture: some Gesture {
    MagnifyGesture()
      .updating($pinchFactor) { value, factor, _ in factor = value.magnification }
      .onEnded { value in
        state.cancelGlide()
        state.zoom = min(max(state.zoom * value.magnification, state.minZoom), state.maxZoom)
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

  // MARK: - Controls

  private var zoomControls: some View {
    @Bindable var state = state
    return HStack(spacing: 8) {
      Text("−").foregroundStyle(Theme.phosphor)
      Slider(
        value: Binding(
          get: { log(state.zoom) },
          set: {
            state.cancelGlide()
            state.zoom = min(max(exp($0), state.minZoom), state.maxZoom)
          }
        ),
        in: log(state.minZoom)...log(state.maxZoom)
      )
      .frame(width: 160)
      .tint(Theme.phosphorDim)
      Text("+").foregroundStyle(Theme.phosphor)
    }
    .font(.system(.body, design: .monospaced).weight(.bold))
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6).fill(Theme.groundRaised.opacity(0.85)))
    .padding(10)
  }

  // MARK: - Drawing

  private func drawEdges(
    _ root: Node, layout: GraphLayout, transform: CanvasTransform,
    glow: Set<String>?, in context: inout GraphicsContext
  ) {
    context.drawLayer { layer in
      layer.addFilter(.shadow(color: Theme.phosphor.opacity(0.5), radius: 3))
      var litPath = Path()
      var dimPath = Path()
      var inertPath = Path()
      walk(root) { node in
        guard let from = layout.positions[node.id] else { return }
        for child in node.children {
          guard let to = layout.positions[child.id] else { continue }
          let segment = trace(from: from, to: to, childID: child.id, transform: transform)
          // A trace is lit when it runs along the selected path or fans out
          // of the selected node.
          let lit =
            glow == nil
            ? false
            : (glow!.contains(child.id)
              && (glow!.contains(node.id) || node.id == "root"))
          if child.status.isInert {
            inertPath.addPath(segment)
          } else if lit {
            litPath.addPath(segment)
          } else {
            dimPath.addPath(segment)
          }
        }
      }
      let dimOpacity = glow == nil ? 0.75 : 0.28
      layer.stroke(dimPath, with: .color(Theme.phosphorDim.opacity(dimOpacity)), lineWidth: 1)
      layer.stroke(inertPath, with: .color(Theme.ash.opacity(glow == nil ? 0.3 : 0.15)), lineWidth: 1)
      layer.stroke(litPath, with: .color(Theme.phosphor.opacity(0.95)), lineWidth: 1.6)
    }
  }

  /// Circuit-board routing in polar space: out along the spoke, around the
  /// board on an intermediate ring, out again to the child. The junction
  /// ring varies a little per trace (stable byte-sum, launch-deterministic)
  /// so parallel traces layer instead of stacking.
  private func trace(
    from: GraphLayout.Position, to: GraphLayout.Position,
    childID: String, transform: CanvasTransform
  ) -> Path {
    var path = Path()
    let r1 = hypot(from.x, from.y)
    let r2 = hypot(to.x, to.y)
    let a = transform.apply(from)
    let b = transform.apply(to)

    // From the center (or a negligible ring), the trace is a straight spoke.
    guard r1 > 5, r2 > r1 + 8 else {
      path.move(to: a)
      path.addLine(to: b)
      return path
    }

    let theta1 = atan2(from.y, from.x)
    let theta2 = atan2(to.y, to.x)
    var deltaTheta = theta2 - theta1
    while deltaTheta > .pi { deltaTheta -= 2 * .pi }
    while deltaTheta < -.pi { deltaTheta += 2 * .pi }

    let byteSum = childID.utf8.reduce(0) { $0 &+ Int($1) }
    let junction = r1 + (r2 - r1) * (0.38 + Double(byteSum % 5) * 0.06)
    let origin = transform.apply(.init(x: 0, y: 0))
    let junctionOut = transform.apply(
      .init(x: junction * cos(theta1), y: junction * sin(theta1)))

    path.move(to: a)
    path.addLine(to: junctionOut)
    if abs(deltaTheta) > 0.004 {
      path.addArc(
        center: origin,
        radius: junction * Double(transform.scale),
        startAngle: .radians(theta1),
        endAngle: .radians(theta2),
        clockwise: deltaTheta < 0)
    }
    path.addLine(to: b)
    return path
  }

  private func drawNodes(
    _ root: Node, layout: GraphLayout, transform: CanvasTransform,
    glow: Set<String>?, in context: inout GraphicsContext
  ) {
    let zoom = transform.scale

    walk(root) { node in
      guard let position = layout.positions[node.id] else { return }
      let center = transform.apply(position)
      let inert = node.status.isInert
      let selected = node.id == state.selectedNodeID
      let lit = glow?.contains(node.id) ?? true
      let recede = glow != nil && !lit
      // A pruned node still opens onward — the band just hides it for now.
      let hidesMore = node.extras["__ms_pruned"] != nil
      // Constant screen size: the space zooms, the nodes do not.
      let radius = node.isDual ? dualRadius : nodeRadius

      let primary: Color = inert ? Theme.ash : (node.isDual ? Theme.magenta : Theme.phosphor)

      context.drawLayer { layer in
        if recede { layer.opacity = 0.35 }
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

      // Key glyph, constant size — the address of the node.
      context.draw(
        Text(node.key ?? "·")
          .font(.system(size: node.isDual ? 14 : 12, design: .monospaced).weight(.bold))
          .foregroundStyle(glyphColor(for: node).opacity(recede ? 0.35 : 1)),
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
                : (inert ? Theme.ash.opacity(0.6) : Theme.ash)),
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

