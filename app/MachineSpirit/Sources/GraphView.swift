import MachineSpiritKit
import SwiftUI

/// The altar: the same model as the witness tree, projected onto a
/// pan/zoom node-graph canvas. Deterministic tidy-tree layout — no wobble.
///
/// The glyph language (the proof this is not a prettier Leader Key clone):
///   action  = filled core
///   group   = halo ring
///   both    = ring AND core, both lit — group+action duality
///   inert   = ashen ghost
struct GraphView: View {
  @Environment(AppState.self) private var state

  @State private var zoom: CGFloat = 0.9
  @State private var pan: CGSize = .zero
  @GestureState private var dragDelta: CGSize = .zero
  @GestureState private var pinchFactor: CGFloat = 1

  private let nodeRadius: CGFloat = 13
  private let minZoom: CGFloat = 0.03
  private let maxZoom: CGFloat = 6

  var body: some View {
    GeometryReader { geometry in
      let model = state.displayModel
      let layout = model.map { TidyTreeLayout.layout(root: $0) }

      Canvas { context, size in
        guard let model, let layout else { return }
        let transform = canvasTransform(layout: layout, viewport: size)
        drawEdges(model, layout: layout, transform: transform, in: &context)
        drawNodes(model, layout: layout, transform: transform, in: &context)
      }
      .background(Theme.ground)
      .contentShape(Rectangle())
      .gesture(panGesture)
      .simultaneousGesture(zoomGesture)
      .onTapGesture { location in
        guard let model, let layout else { return }
        let transform = canvasTransform(layout: layout, viewport: geometry.size)
        let hitID = hitTest(location, in: model, layout: layout, transform: transform)
        state.selectedNodeID = hitID
        // Striking a sheol verb node acts: revive fires; banish arms ◆◆◇.
        if let hitID, let node = model.node(withID: hitID) {
          _ = state.strikeSheolNode(node)
        }
      }
      .onAppear {
        // Landing from the witness: center the shared selection, sane zoom.
        if let layout { centerSelection(layout: layout, viewport: geometry.size) }
      }
    }
    .clipped()
    .overlay(alignment: .topTrailing) { zoomControls }
  }

  /// Slider + ⌘= / ⌘- — pinch still works; scroll-wheel zoom is Phase 2.
  private var zoomControls: some View {
    HStack(spacing: 8) {
      Button("−") { zoom = max(zoom / 1.25, minZoom) }
        .keyboardShortcut("-", modifiers: .command)
      Slider(
        value: Binding(
          get: { log(zoom) },
          set: { zoom = min(max(exp($0), minZoom), maxZoom) }
        ),
        in: log(minZoom)...log(maxZoom)
      )
      .frame(width: 160)
      .tint(Theme.phosphorDim)
      Button("+") { zoom = min(zoom * 1.25, maxZoom) }
        .keyboardShortcut("=", modifiers: .command)
    }
    .buttonStyle(.plain)
    .font(.system(.body, design: .monospaced).weight(.bold))
    .foregroundStyle(Theme.phosphor)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6).fill(Theme.groundRaised.opacity(0.85)))
    .padding(10)
  }

  private func centerSelection(layout: GraphLayout, viewport: CGSize) {
    guard let id = state.selectedNodeID,
      let position = layout.positions[id]
    else { return }
    if zoom < 0.8 { zoom = 1.0 }
    let base = CGSize(
      width: 60 * zoom,
      height: viewport.height / 2 - layout.height / 2 * zoom)
    pan = CGSize(
      width: viewport.width / 2 - position.x * zoom - base.width,
      height: viewport.height / 2 - position.y * zoom - base.height)
  }

  // MARK: - Viewport math

  private var effectiveZoom: CGFloat { zoom * pinchFactor }

  private var effectivePan: CGSize {
    CGSize(width: pan.width + dragDelta.width, height: pan.height + dragDelta.height)
  }

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

  private func canvasTransform(layout: GraphLayout, viewport: CGSize) -> CanvasTransform {
    // Root rests near the left edge, vertically centered, then the user's
    // pan/zoom rides on top.
    let base = CGSize(
      width: 60 * effectiveZoom,
      height: viewport.height / 2 - layout.height / 2 * effectiveZoom)
    return CanvasTransform(
      scale: effectiveZoom,
      offset: CGSize(
        width: base.width + effectivePan.width,
        height: base.height + effectivePan.height))
  }

  private var panGesture: some Gesture {
    DragGesture(minimumDistance: 2)
      .updating($dragDelta) { value, delta, _ in delta = value.translation }
      .onEnded { value in
        pan.width += value.translation.width
        pan.height += value.translation.height
      }
  }

  private var zoomGesture: some Gesture {
    MagnifyGesture()
      .updating($pinchFactor) { value, factor, _ in factor = value.magnification }
      .onEnded { value in
        zoom = min(max(zoom * value.magnification, minZoom), maxZoom)
      }
  }

  private func hitTest(
    _ point: CGPoint, in model: Node, layout: GraphLayout, transform: CanvasTransform
  ) -> String? {
    let world = transform.unapply(point)
    let reach = Double(nodeRadius + 8) / Double(transform.scale)
    var best: (id: String, distance: Double)?
    for (id, position) in layout.positions {
      let distance = hypot(position.x - world.x, position.y - world.y)
      if distance <= reach, distance < (best?.distance ?? .infinity) {
        best = (id, distance)
      }
    }
    return best?.id
  }

  // MARK: - Drawing

  private func drawEdges(
    _ root: Node, layout: GraphLayout, transform: CanvasTransform,
    in context: inout GraphicsContext
  ) {
    context.drawLayer { layer in
      layer.addFilter(.shadow(color: Theme.phosphor.opacity(0.5), radius: 3))
      var path = Path()
      var inertPath = Path()
      walk(root) { node in
        guard let from = layout.positions[node.id] else { return }
        for child in node.children {
          guard let to = layout.positions[child.id] else { continue }
          let a = transform.apply(from)
          let b = transform.apply(to)
          let midX = (a.x + b.x) / 2
          var segment = Path()
          segment.move(to: a)
          segment.addCurve(
            to: b,
            control1: CGPoint(x: midX, y: a.y),
            control2: CGPoint(x: midX, y: b.y))
          if child.status.isInert {
            inertPath.addPath(segment)
          } else {
            path.addPath(segment)
          }
        }
      }
      layer.stroke(path, with: .color(Theme.phosphorDim.opacity(0.75)), lineWidth: 1)
      layer.stroke(inertPath, with: .color(Theme.ash.opacity(0.3)), lineWidth: 1)
    }
  }

  private func drawNodes(
    _ root: Node, layout: GraphLayout, transform: CanvasTransform,
    in context: inout GraphicsContext
  ) {
    let scale = transform.scale
    let radius = nodeRadius * scale

    walk(root) { node in
      guard let position = layout.positions[node.id] else { return }
      let center = transform.apply(position)
      let inert = node.status.isInert
      let selected = node.id == state.selectedNodeID

      let primary: Color =
        inert
        ? Theme.ash
        : (node.isDual || Theme.isNecromantic(node) ? Theme.magenta : Theme.phosphor)

      context.drawLayer { layer in
        if !inert {
          layer.addFilter(
            .shadow(color: primary.opacity(selected ? 0.9 : 0.45), radius: selected ? 8 : 4))
        }

        // Dark disc so glyphs and crossing edges never fight.
        let discRect = CGRect(
          x: center.x - radius, y: center.y - radius,
          width: radius * 2, height: radius * 2)
        layer.fill(Circle().path(in: discRect), with: .color(Theme.ground))

        // Halo ring — this node opens onward (a group).
        if node.isGroup {
          layer.stroke(
            Circle().path(in: discRect),
            with: .color(primary.opacity(inert ? 0.5 : 1)),
            lineWidth: (selected ? 2.5 : 1.5) * scale)
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
              with: .color(primary.opacity(0.8)), lineWidth: 1.5 * scale)
          }
        }
      }

      // Key glyph, large — the address of the node.
      if scale > 0.28 {
        context.draw(
          Text(node.key ?? "·")
            .font(.system(size: 12 * scale, design: .monospaced).weight(.bold))
            .foregroundStyle(glyphColor(for: node)),
          at: CGPoint(x: center.x, y: center.y))
      }

      // Name/summary, small, beside the node.
      if scale > 0.55 {
        context.draw(
          Text(node.displayName)
            .font(.system(size: 8.5 * scale, design: .monospaced))
            .foregroundStyle(inert ? Theme.ash.opacity(0.6) : Theme.ash),
          at: CGPoint(x: center.x, y: center.y + radius + 8 * scale))
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
