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
    startAngle: Double = -Double.pi / 2
  ) -> GraphLayout {
    var positions: [String: GraphLayout.Position] = [:]
    var maxRadius = 0.0

    func leafWeight(_ node: Node) -> Int {
      node.children.isEmpty ? 1 : node.children.reduce(0) { $0 + leafWeight($1) }
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
      let pressured =
        radius <= 0
        ? radius
        : min(max(radius, minSpacing / max(span, 0.0001)), radius + 3 * ringStep)
      let angle = (from + to) / 2
      positions[node.id] = .init(
        x: pressured * cos(angle), y: pressured * sin(angle))
      maxRadius = max(maxRadius, pressured)

      guard !node.children.isEmpty else { return }
      let step = node.children.count == 1 ? chainStep : ringStep
      let total = Double(leafWeight(node))
      var cursor = from
      for child in node.children {
        let share = span * Double(leafWeight(child)) / total
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
