import Foundation

/// Radial tidy layout — the graph grows 360° from a center, ring per depth.
/// Deterministic: a pure function of the tree, identical on every launch.
///
/// The root sits at the origin (one center per leader key — multiple middles
/// are a Phase-2 graph concern; the math already permits any origin).
/// Angular span is allocated proportionally to leaf weight, so siblings never
/// overlap at their ring. Single-child chains take a shorter radial hop, so
/// mnemonic runs (`q-u-i-t`) read as tight spokes.
public enum RadialLayout {
  public static func layout(
    root: Node,
    ringStep: Double = 150,
    chainStep: Double = 66,
    minSpacing: Double = 40,
    startAngle: Double = -Double.pi / 2,
    stackLeafClusters: Bool = false,
    stackRow: Double = 30,
    stackIndent: Double = 26,
    leafWeight weigh: (Node) -> Double = { _ in 1 }
  ) -> GraphLayout {
    var positions: [String: GraphLayout.Position] = [:]
    var maxRadius = 0.0

    // Leaf weight drives angular allocation. The default treats every leaf
    // equally; the app passes label width at readable zooms so wide labels
    // get wide arcs — spread where the information actually is.
    func leafWeight(_ node: Node) -> Double {
      node.children.isEmpty
        ? max(weigh(node), 0.1)
        : node.children.reduce(0) { $0 + leafWeight($1) }
    }

    // Place a node at (radius, mid-angle of its span), then divide the span
    // among children by leaf weight. Arc pressure: a node whose angular
    // share is too tight for `minSpacing` slides outward until its arc can
    // hold it — crowded regions breathe outward organically, sparse spokes
    // stay close to their ring.
    func place(_ node: Node, radius: Double, from: Double, to: Double) {
      let span = to - from
      // Pressure is capped so one hyper-crowded pocket can't balloon the
      // whole graph's diameter (it may locally re-crowd; semantic zoom in
      // the app thins those depths before they're ever dense on screen).
      var pressured =
        radius <= 0
        ? radius
        : min(max(radius, minSpacing / max(span, 0.0001)), radius + 3 * ringStep)
      // Crowded leaves stagger across three shells instead of packing one
      // rim — deterministic (byte-sum), so labels and nodes get air.
      if node.children.isEmpty, pressured > 0, span < minSpacing / pressured * 2.2 {
        let byteSum = node.id.utf8.reduce(0) { $0 &+ Int($1) }
        pressured += Double(byteSum % 3) * ringStep * 0.34
      }
      let angle = (from + to) / 2
      positions[node.id] = .init(
        x: pressured * cos(angle), y: pressured * sin(angle))
      maxRadius = max(maxRadius, pressured)

      guard !node.children.isEmpty else { return }

      // Interlocked stagger: a parent whose children are ALL leaves packs
      // them into an offset column outward of itself — the (*-_) pattern —
      // so labels interleave instead of fighting for one arc.
      if stackLeafClusters, node.children.count >= 2,
        node.children.allSatisfy({ $0.children.isEmpty })
      {
        let angle = (from + to) / 2
        let stackRadius = pressured + ringStep
        let centerX = stackRadius * cos(angle)
        let centerY = stackRadius * sin(angle)
        let outwardSign: Double = cos(angle) >= 0 ? 1 : -1
        for (index, child) in node.children.enumerated() {
          let row = Double(index) - Double(node.children.count - 1) / 2
          let x = centerX + (index % 2 == 1 ? stackIndent * outwardSign : 0)
          let y = centerY + row * stackRow
          positions[child.id] = .init(x: x, y: y)
          maxRadius = max(maxRadius, (x * x + y * y).squareRoot())
        }
        return
      }

      let step = node.children.count == 1 ? chainStep : ringStep
      let total = leafWeight(node)
      var cursor = from
      for child in node.children {
        let share = span * leafWeight(child) / total
        place(child, radius: pressured + step, from: cursor, to: cursor + share)
        cursor += share
      }
    }

    place(root, radius: 0, from: startAngle, to: startAngle + 2 * Double.pi)

    return GraphLayout(
      positions: positions,
      width: maxRadius * 2,
      height: maxRadius * 2
    )
  }
}
