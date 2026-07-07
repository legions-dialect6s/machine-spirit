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
  /// The ACTIVE position overrides (what the canvas renders right now).
  public var nodes: [String: NodeViewState]
  /// Named layouts that persist regardless of which one is active —
  /// switching layouts must never destroy an arrangement ("hand" holds the
  /// owner's; "radial" is never stored, it's always recomputable). Optional
  /// so pre-layout sidecars keep decoding.
  public var layouts: [String: [String: NodeViewState]]?
  /// Which named layout `nodes` was projected from ("radial" / "hand").
  /// nil = a pre-layout sidecar: its `nodes` ARE the hand layout (migration).
  public var activeLayout: String?

  public init(
    zoom: Double = 1.0,
    panX: Double = 0,
    panY: Double = 0,
    nodes: [String: NodeViewState] = [:],
    layouts: [String: [String: NodeViewState]]? = nil,
    activeLayout: String? = nil
  ) {
    self.zoom = zoom
    self.panX = panX
    self.panY = panY
    self.nodes = nodes
    self.layouts = layouts
    self.activeLayout = activeLayout
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
