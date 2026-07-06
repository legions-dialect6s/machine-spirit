import Foundation

/// View-metadata sidecar for the node-graph canvas: positions, zoom,
/// collapsed flags — keyed by structural node id (`root/g/p`).
///
/// This is app-owned presentation state, serialized as its OWN JSON file in
/// Application Support. It never pollutes the core config model, and it is
/// never written into Leader Key's config. Path-based ids are sufficient
/// while Phase 1 is read-only; durable ids are a Phase-2 problem.
public struct GraphViewState: Codable, Equatable, Sendable {
  public struct NodeViewState: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var collapsed: Bool

    public init(x: Double, y: Double, collapsed: Bool = false) {
      self.x = x
      self.y = y
      self.collapsed = collapsed
    }
  }

  public var zoom: Double
  public var panX: Double
  public var panY: Double
  public var nodes: [String: NodeViewState]

  public init(
    zoom: Double = 1.0,
    panX: Double = 0,
    panY: Double = 0,
    nodes: [String: NodeViewState] = [:]
  ) {
    self.zoom = zoom
    self.panX = panX
    self.panY = panY
    self.nodes = nodes
  }

  public func data() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }

  public static func load(from data: Data) throws -> GraphViewState {
    try JSONDecoder().decode(GraphViewState.self, from: data)
  }
}
