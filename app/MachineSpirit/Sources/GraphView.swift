import AppKit
import MachineSpiritKit
import SwiftUI

/// The node graph. Every node renders at every zoom — far out they shrink,
/// but icons, lines, words and labels never vanish. Drag a node to move it
/// (roots move their whole tree; ⌘-click gathers a group; ⌘-drag on space
/// rubber-bands one), drag space to pan. Positions and viewport persist.
struct GraphView: View {
  @Environment(AppState.self) private var state

  @GestureState private var pinchFactor: CGFloat = 1

  private enum DragMode {
    case pan(applied: CGSize)
    case move(origins: [String: GraphLayout.Position])
    case select(anchor: CGPoint)
  }
  @State private var dragMode: DragMode?
  @State private var selectionRect: CGRect?

  private let nodeRadius: CGFloat = 13
  private let dualRadius: CGFloat = 18
  private let growthDuration = 0.85

  var body: some View {
    GeometryReader { geometry in
      let model = state.displayModel
      let layout = model.map { combinedLayout(for: $0) }
      let roots: [Node] = model.map { [$0, AppState.auxLeader] } ?? []
      let spelledWords = model.map { chainWords(in: $0) } ?? [:]

      let stillness = Date().timeIntervalSince(state.lastDisturbance)
      let settled = Date().timeIntervalSince(state.bootStamp) > growthDuration + 0.6
      TimelineView(
        .animation(minimumInterval: 1.0 / 30.0, paused: settled && stillness > 3.5)
      ) { timeline in
        Canvas { context, size in
          guard let model, let layout else { return }
          _ = state.iconEpoch  // favicons arriving repaint the board
          let transform = canvasTransform(viewport: size)
          let glow = glowSet(in: model)
          let pulse = Pulse(
            now: timeline.date,
            bootStamp: state.bootStamp,
            maxRadius: max(layout.width / 2, 1),
            growthDuration: growthDuration)
          for root in roots {
            drawEdges(
              root, layout: layout, transform: transform, glow: glow, pulse: pulse,
              in: &context)
          }
          for root in roots {
            drawNodes(
              root, layout: layout, transform: transform, glow: glow, pulse: pulse,
              chainWords: spelledWords, in: &context)
          }
          if let rect = selectionRect {
            context.stroke(
              Rectangle().path(in: rect),
              with: .color(Theme.phosphorDim.opacity(0.8)), lineWidth: 1)
            context.fill(
              Rectangle().path(in: rect),
              with: .color(Theme.phosphor.opacity(0.06)))
          }
        }
      }
      .background(Theme.ground)
      .onGeometryChange(for: CGRect.self) { proxy in
        proxy.frame(in: .global)
      } action: { frame in
        state.graphFrame = frame
      }
      .contentShape(Rectangle())
      .gesture(dragGesture(layout: layout, viewport: geometry.size))
      .simultaneousGesture(zoomGesture)
      .onTapGesture { location in
        guard let layout else { return }
        let transform = canvasTransform(viewport: geometry.size)
        let hitID = hitTest(location, in: layout, transform: transform)
        let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if let hitID {
          if commandHeld {
            if state.multiSelection.contains(hitID) {
              state.multiSelection.remove(hitID)
            } else {
              state.multiSelection.insert(hitID)
            }
          } else {
            state.multiSelection = []
            state.selectedNodeID = hitID
            state.revealSelectionInTree()
          }
        } else if !commandHeld {
          state.multiSelection = []
          state.selectedNodeID = nil
        }
      }
      .onChange(of: state.selectedNodeID) {
        // Center on the TRUE position — stacks, drags and all. (The old
        // bug: centering against the undragged layout sent you elsewhere.)
        guard let id = state.selectedNodeID, let model,
          let position = combinedLayout(for: model).positions[id]
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

  // MARK: - Time (growth only — the sway is retired)

  private struct Pulse {
    let elapsed: Double
    let maxRadius: Double
    let growthDuration: Double

    init(now: Date, bootStamp: Date, maxRadius: Double, growthDuration: Double) {
      elapsed = now.timeIntervalSince(bootStamp)
      self.maxRadius = maxRadius
      self.growthDuration = growthDuration
    }

    var growing: Bool { elapsed < growthDuration }

    func reveal(atRadius radius: Double, lag: Double = 0) -> Double {
      guard growing else { return 1 }
      let delay = radius / maxRadius * (growthDuration * 0.5) + lag
      return min(max((elapsed - delay) / 0.25, 0), 1)
    }
  }

  // MARK: - Layout (main board + the aux leader, one space, overrides last)

  private func combinedLayout(for model: Node) -> GraphLayout {
    var layout = RadialLayout.layout(
      root: model, ringStep: 165, chainStep: 80, minSpacing: 48,
      stackLeafClusters: true, stackRow: 32, stackIndent: 30)
    let aux = RadialLayout.layout(root: AppState.auxLeader, ringStep: 130)
    let auxOffsetX = layout.width / 2 + aux.width / 2 + 420
    for (id, position) in aux.positions {
      layout.positions[id] = .init(x: position.x + auxOffsetX, y: position.y)
    }
    for (id, position) in state.nodeOverrides where layout.positions[id] != nil {
      layout.positions[id] = position
    }
    return layout
  }

  /// Leaf ends of single-child chains spell their word; the glyph carries
  /// the first letter and the box trails the rest — q»uit.
  private func chainWords(in model: Node) -> [String: String] {
    var words: [String: String] = [:]
    func descend(_ node: Node, inheritedRun: [String]) {
      let run = inheritedRun + [node.key ?? ""]
      if node.children.isEmpty, run.count >= 3 {
        let word = run.joined()
        if word.count >= 3 { words[node.id] = word }
      }
      for child in node.children {
        descend(child, inheritedRun: node.children.count == 1 ? run : [node.key ?? ""])
      }
    }
    for child in model.children { descend(child, inheritedRun: []) }
    return words
  }

  // MARK: - Viewport math

  private var effectiveZoom: CGFloat { state.zoom * pinchFactor }

  /// Far out, nodes shrink — but never vanish.
  private var nodeScale: CGFloat { min(1, max(0.42, 0.5 + effectiveZoom * 0.55)) }

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
        width: viewport.width / 2 + state.pan.width,
        height: viewport.height / 2 + state.pan.height))
  }

  // MARK: - Gestures

  private func dragGesture(layout: GraphLayout?, viewport: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { value in
        if dragMode == nil {
          state.cancelGlide()
          let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
          let transform = canvasTransform(viewport: viewport)
          if let layout,
            let hitID = hitTest(value.startLocation, in: layout, transform: transform)
          {
            var moving: Set<String>
            if hitID == "root" || hitID == "mb4" {
              // Dragging a leader carries its whole tree.
              moving = Set(layout.positions.keys.filter {
                $0 == hitID || $0.hasPrefix(hitID + "/")
              })
            } else if state.multiSelection.contains(hitID) {
              moving = state.multiSelection
            } else {
              moving = [hitID]
            }
            var origins: [String: GraphLayout.Position] = [:]
            for id in moving {
              origins[id] = state.nodeOverrides[id] ?? layout.positions[id]
            }
            dragMode = .move(origins: origins)
          } else if commandHeld {
            dragMode = .select(anchor: value.startLocation)
          } else {
            dragMode = .pan(applied: .zero)
          }
        }
        switch dragMode {
        case .pan(let applied):
          state.pan.width += value.translation.width - applied.width
          state.pan.height += value.translation.height - applied.height
          state.disturb()
          dragMode = .pan(applied: value.translation)
        case .move(let origins):
          for (id, origin) in origins {
            state.nodeOverrides[id] = .init(
              x: origin.x + value.translation.width / Double(effectiveZoom),
              y: origin.y + value.translation.height / Double(effectiveZoom))
          }
          state.disturb()
        case .select(let anchor):
          selectionRect = CGRect(
            x: min(anchor.x, value.location.x),
            y: min(anchor.y, value.location.y),
            width: abs(value.location.x - anchor.x),
            height: abs(value.location.y - anchor.y))
          state.disturb()
        case nil:
          break
        }
      }
      .onEnded { value in
        if case .move = dragMode { state.saveSidecar() }
        if case .select = dragMode, let rect = selectionRect, let layout {
          let transform = canvasTransform(viewport: viewport)
          state.multiSelection = Set(
            layout.positions.compactMap { id, position in
              rect.contains(transform.apply(position)) ? id : nil
            })
        }
        selectionRect = nil
        dragMode = nil
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

  /// The lit path: selection's line from the center plus its whole subtree.
  private func glowSet(in model: Node) -> Set<String>? {
    guard let id = state.selectedNodeID else { return nil }
    var lit = Set(AppState.ancestorIDs(of: id))
    lit.insert(id)
    if let node = model.node(withID: id) ?? AppState.auxLeader.node(withID: id) {
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
      if !state.nodeOverrides.isEmpty {
        Button {
          state.clearOverrides()
        } label: {
          Label("sort", systemImage: "arrow.triangle.2.circlepath")
            .font(.system(size: 11, design: .monospaced))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.phosphorDim)
        .help("return dragged nodes to the radial order")
      }
      Button {} label: {
        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(Theme.ash.opacity(0.4))
      .disabled(true)
      .help("adding nodes arrives with config write-back — a later phase, honestly")
      Button {} label: {
        Image(systemName: "minus").font(.system(size: 11, weight: .bold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(Theme.ash.opacity(0.4))
      .disabled(true)
      .help("removing nodes arrives with config write-back — a later phase, honestly")
    }
    .font(.system(size: 12, design: .monospaced).weight(.bold))
    .padding(8)
    .opacity(0.85)
  }

  // MARK: - Drawing

  private func color(of node: Node) -> Color {
    if case .application(let path) = node.action, node.status.isInert == false {
      return IconStore.tint(forPath: (path as NSString).expandingTildeInPath)
    }
    if case .command(let value) = node.action, node.status.isInert == false,
      let domain = IconStore.webJumpDomain(in: value)
    {
      return IconStore.tint(forPath: "favicon:\(domain)")
    }
    return Theme.nodeColor(for: node)
  }

  private func drawEdges(
    _ root: Node, layout: GraphLayout, transform: CanvasTransform,
    glow: Set<String>?, pulse: Pulse, in context: inout GraphicsContext
  ) {
    // Obstacle field for the light avoid-pass: every node position.
    let obstacles = layout.positions

    context.drawLayer { layer in
      layer.addFilter(.shadow(color: Theme.phosphor.opacity(0.45), radius: 3))
      walk(root) { node in
        guard let from = layout.positions[node.id] else { return }
        let parentColor = node.id == root.id ? Theme.phosphorDim : color(of: node)
        let siblingCount = node.children.count
        for (index, child) in node.children.enumerated() {
          guard let to = layout.positions[child.id] else { continue }
          var segment = trace(
            from: from, to: to, childID: child.id, index: index,
            siblings: siblingCount, obstacles: obstacles,
            excluding: [node.id, child.id], transform: transform)

          let reveal = pulse.reveal(atRadius: hypot(to.x, to.y))
          if reveal <= 0 { continue }
          if reveal < 1 { segment = segment.trimmedPath(from: 0, to: reveal) }

          let depth = child.id.split(separator: "/").count - 1
          let lit =
            glow == nil
            ? false
            : (glow!.contains(child.id) && (glow!.contains(node.id) || node.id == root.id))
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

  private func taper(_ depth: Int) -> CGFloat {
    max(0.85, 2.0 * pow(0.88, CGFloat(max(depth - 1, 0))))
  }

  /// One trace: a smooth cubic riding a sibling-staggered junction, bowed
  /// away from any node it would otherwise cut through — the lines find
  /// their way around for visual flow.
  private func trace(
    from: GraphLayout.Position, to: GraphLayout.Position,
    childID: String, index: Int, siblings: Int,
    obstacles: [String: GraphLayout.Position], excluding: Set<String>,
    transform: CanvasTransform
  ) -> Path {
    var path = Path()
    let a = transform.apply(from)
    let b = transform.apply(to)

    // Obstacle avoidance in world space: strongest violation wins a bow.
    var bow = 0.0
    let dx = to.x - from.x
    let dy = to.y - from.y
    let length = max(hypot(dx, dy), 0.001)
    for (id, obstacle) in obstacles where !excluding.contains(id) {
      let t = ((obstacle.x - from.x) * dx + (obstacle.y - from.y) * dy) / (length * length)
      guard t > 0.08, t < 0.92 else { continue }
      let closestX = from.x + t * dx
      let closestY = from.y + t * dy
      let distance = hypot(obstacle.x - closestX, obstacle.y - closestY)
      let clearance = 26.0
      if distance < clearance {
        let side: Double = (obstacle.x - closestX) * dy - (obstacle.y - closestY) * dx >= 0 ? -1 : 1
        let push = (clearance - distance + 8) * side
        if abs(push) > abs(bow) { bow = push }
      }
    }

    let byteSum = childID.utf8.reduce(0) { $0 &+ Int($1) }
    let fraction = siblings <= 1 ? 0.5 : 0.34 + 0.32 * Double(index) / Double(siblings - 1)
    let lean = Double(byteSum % 9 - 4) * 2.0

    let perpX = -dy / length
    let perpY = dx / length
    let control1 = transform.apply(
      x: from.x + dx * fraction * 0.7 + perpX * (bow + lean),
      y: from.y + dy * fraction * 0.7 + perpY * (bow + lean))
    let control2 = transform.apply(
      x: from.x + dx * (0.3 + fraction * 0.7) + perpX * bow,
      y: from.y + dy * (0.3 + fraction * 0.7) + perpY * bow)

    path.move(to: a)
    path.addCurve(to: b, control1: control1, control2: control2)
    return path
  }

  private func drawNodes(
    _ root: Node, layout: GraphLayout, transform: CanvasTransform,
    glow: Set<String>?, pulse: Pulse, chainWords: [String: String],
    in context: inout GraphicsContext
  ) {
    let sizeScale = nodeScale

    walk(root) { node in
      guard let position = layout.positions[node.id] else { return }
      let birth = pulse.reveal(atRadius: hypot(position.x, position.y), lag: 0.12)
      if birth <= 0 { return }

      let center = transform.apply(position)
      let inert = node.status.isInert
      let selected = node.id == state.selectedNodeID || state.multiSelection.contains(node.id)
      let lit = glow?.contains(node.id) ?? true
      let recede = glow != nil && !lit
      let isLeaderRoot = node.id == root.id
      let radius =
        (isLeaderRoot ? dualRadius : (node.isDual ? dualRadius : nodeRadius))
        * sizeScale * (birth < 1 ? birth : 1)

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

        if birth > 0.8, !inert, let iconPath = IconStore.iconPath(for: node),
          let icon = IconStore.icon(forPath: iconPath, state: state)
        {
          layer.drawLayer { iconLayer in
            iconLayer.clip(to: Circle().path(in: discRect.insetBy(dx: 1.5, dy: 1.5)))
            iconLayer.opacity = recede ? 0.3 : 0.85
            iconLayer.draw(icon, in: discRect.insetBy(dx: 1.5, dy: 1.5))
          }
        }

        if node.isGroup || isLeaderRoot {
          layer.stroke(
            Circle().path(in: discRect),
            with: .color(primary.opacity(inert ? 0.5 : 1)),
            lineWidth: selected ? 2.5 : 1.5)
        }
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

      let word = chainWords[node.id]
      // The glyph: leaders wear their key; chain ends wear the word's first
      // letter (the rest trails in the box — q»uit, no doubled letters).
      let glyphText: String
      if node.id == "root" {
        glyphText = "⇪"
      } else if isLeaderRoot {
        glyphText = node.key ?? "·"
      } else if let word {
        glyphText = String(word.prefix(1))
      } else {
        glyphText = node.key ?? "·"
      }
      let glyphSize = (node.id == "root" ? 17.0 : (node.isDual ? 14.0 : 12.0)) * sizeScale
      let glyphBack = CGRect(
        x: center.x - 7 * sizeScale, y: center.y - 7.5 * sizeScale,
        width: 14 * sizeScale, height: 15 * sizeScale)
      context.fill(
        RoundedRectangle(cornerRadius: 4).path(in: glyphBack),
        with: .color(Theme.ground.opacity(recede ? 0.4 : 0.75)))
      context.draw(
        Text(glyphText)
          .font(.system(size: glyphSize, design: .monospaced).weight(.bold))
          .foregroundStyle(glyphColor(for: node).opacity(recede ? 0.35 : Double(birth))),
        at: center)

      // The word box trails the remaining letters off the disc.
      var wordBoxWidth = 0.0
      if let word {
        let trailing = String(word.dropFirst())
        let wordText = context.resolve(
          Text(trailing)
            .font(.system(size: 11.5 * sizeScale, design: .monospaced).weight(.bold))
            .foregroundStyle(
              (inert ? Theme.ash : Theme.phosphor).opacity(recede ? 0.3 : Double(birth))))
        let wordSize = wordText.measure(in: CGSize(width: 240, height: 30))
        let box = CGRect(
          x: center.x + radius + 2,
          y: center.y - wordSize.height / 2 - 2,
          width: wordSize.width + 8,
          height: wordSize.height + 4)
        context.fill(
          RoundedRectangle(cornerRadius: 4).path(in: box),
          with: .color(Theme.groundRaised.opacity(recede ? 0.3 : 0.9)))
        context.stroke(
          RoundedRectangle(cornerRadius: 4).path(in: box),
          with: .color(Theme.phosphorDim.opacity(recede ? 0.2 : 0.7)),
          lineWidth: 1)
        context.draw(
          wordText,
          in: CGRect(
            x: box.minX + 4, y: box.minY + 2,
            width: wordSize.width, height: wordSize.height))
        wordBoxWidth = box.width + 6
      }

      // Labels never hide — the board is for reading.
      if !isLeaderRoot || node.id == "mb4" {
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
        if anchor == .leading, wordBoxWidth > 0 {
          labelPoint.x += wordBoxWidth
        }

        let label = context.resolve(
          Text(node.displayName)
            .font(.system(size: 10.5 * max(sizeScale, 0.7), design: .monospaced))
            .foregroundStyle(
              recede
                ? Theme.ash.opacity(0.25)
                : (inert ? Theme.ash.opacity(0.6) : Color(white: 0.64).opacity(Double(birth)))))
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
