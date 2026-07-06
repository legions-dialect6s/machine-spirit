import Foundation

/// Whether a node's dependencies are present on this machine right now.
/// Derived at import time by an `AvailabilityProbe`, recomputed on every
/// import, and never serialized into the config model.
public enum RuntimeStatus: Equatable, Sendable {
  case active
  case inert(reason: String)

  public var isInert: Bool {
    if case .inert = self { return true }
    return false
  }

  public var inertReason: String? {
    if case .inert(let reason) = self { return reason }
    return nil
  }
}

/// One node of the input-layer graph.
///
/// The headline capability, deliberately beyond Leader Key's exclusive
/// group/action split: a node may carry BOTH an action AND children. Import
/// never forces duality — current binds map in without restructuring — but
/// the model holds it natively.
public struct Node: Identifiable, Equatable, Sendable {
  /// Structural path id, e.g. `root/g/p`. Sufficient while Phase 1 is
  /// read-only; durable ids are a Phase-2 problem.
  public let id: String
  public var key: String?
  public var label: String?
  public var action: ActionPayload?
  public var children: [Node]

  /// Unknown config fields, preserved verbatim (includes fields Leader Key
  /// knows but this model doesn't lift, e.g. `iconPath`). This bag is what
  /// makes "lossless" a mechanism instead of a claim.
  public var extras: [String: JSONValue]

  /// Derived availability — see `RuntimeStatus`. Not part of the config.
  public var status: RuntimeStatus

  /// Presence facts from import, so serialization reproduces the source
  /// shape exactly: `{}` stays `{}`, never growing a `"type"` or `"actions"`.
  public var hadExplicitType: Bool
  public var hadChildrenArray: Bool

  public init(
    id: String,
    key: String? = nil,
    label: String? = nil,
    action: ActionPayload? = nil,
    children: [Node] = [],
    extras: [String: JSONValue] = [:],
    status: RuntimeStatus = .active,
    hadExplicitType: Bool = true,
    hadChildrenArray: Bool = false
  ) {
    self.id = id
    self.key = key
    self.label = label
    self.action = action
    self.children = children
    self.extras = extras
    self.status = status
    self.hadExplicitType = hadExplicitType
    self.hadChildrenArray = hadChildrenArray
  }

  /// A group in Leader Key's sense: it has children (or was declared one).
  public var isGroup: Bool { !children.isEmpty || action == nil }

  /// The both-at-once case the model exists to hold.
  public var isDual: Bool { action != nil && !children.isEmpty }

  /// Display name, mirroring Leader Key's fallback logic loosely.
  public var displayName: String {
    if let label, !label.isEmpty { return label }
    guard let action else { return "group" }
    switch action {
    case .application(let path):
      return (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    case .folder(let path):
      return (path as NSString).lastPathComponent
    case .command(let value):
      if let windowAction = action.windowAction { return windowAction }
      return value.components(separatedBy: " ").first ?? value
    case .url(let value):
      return value
    case .other(_, let value):
      return value
    }
  }

  /// Depth-first count of this node and everything under it.
  public var totalCount: Int {
    1 + children.reduce(0) { $0 + $1.totalCount }
  }

  /// Depth-first search by structural id.
  public func node(withID id: String) -> Node? {
    if self.id == id { return self }
    for child in children {
      if let found = child.node(withID: id) { return found }
    }
    return nil
  }
}
