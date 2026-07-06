import Foundation

/// Computed node positions for the graph canvas. Pure data — the kit stays
/// UI-free; rendering belongs to the app.
public struct GraphLayout: Equatable, Sendable {
  public struct Position: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
      self.x = x
      self.y = y
    }
  }

  public var positions: [String: Position]
  public var width: Double
  public var height: Double

  public init(positions: [String: Position], width: Double, height: Double) {
    self.positions = positions
    self.width = width
    self.height = height
  }
}

/// Deterministic tidy-tree layout, Reingold–Tilford-style, left→right by
/// depth. No force-directed wobble — legible, calm, identical on every
/// launch (a pure function of the tree).
///
/// Single-child chains compress: a run like `q → q → q` or `q-u-i-t` takes
/// the short `chainStep` per hop instead of the full `columnStep`, so
/// mnemonic sequences read as tight routes, not ladders.
public enum TidyTreeLayout {
  public static func layout(
    root: Node,
    rowHeight: Double = 34,
    columnStep: Double = 190,
    chainStep: Double = 74
  ) -> GraphLayout {
    var positions: [String: GraphLayout.Position] = [:]
    var nextLeafY = 0.0
    var maxX = 0.0

    func place(_ node: Node, x: Double) -> Double {
      maxX = max(maxX, x)
      let y: Double
      if node.children.isEmpty {
        y = nextLeafY
        nextLeafY += rowHeight
      } else {
        let step = node.children.count == 1 ? chainStep : columnStep
        var childYs: [Double] = []
        for child in node.children {
          childYs.append(place(child, x: x + step))
        }
        y = (childYs[0] + childYs[childYs.count - 1]) / 2
      }
      positions[node.id] = .init(x: x, y: y)
      return y
    }

    _ = place(root, x: 0)
    return GraphLayout(
      positions: positions,
      width: maxX,
      height: max(nextLeafY - rowHeight, 0)
    )
  }
}
