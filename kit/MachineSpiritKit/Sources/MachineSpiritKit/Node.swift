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

  /// Display name: explicit labels win; otherwise the node says what it
  /// DOES — `open app Claude`, `open folder projects`, `invoke ss-menu`,
  /// `window maximize` — so the graph explains itself.
  public var displayName: String {
    if let label, !label.isEmpty { return label }
    guard let action else { return "group" }
    switch action {
    case .application(let path):
      let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
      return "open app \(name)"
    case .folder(let path):
      return "open folder \(Node.folderDisplayName(path))"
    case .command(let value):
      if let windowAction = action.windowAction { return "window \(windowAction)" }
      return "invoke \(Node.commandDisplayName(value))"
    case .url(let value):
      return "open url \(value)"
    case .other(_, let value):
      return value
    }
  }

  /// Home-anchored folder path for display: a folder directly under home is
  /// just its name; deeper ones show the home-relative path; system paths
  /// (`/Applications`) stay absolute. Never shows the username.
  static func folderDisplayName(_ path: String) -> String {
    var relative = path.trimmingCharacters(in: .whitespaces)
    var wasHomeAnchored = false
    for prefix in ["__HOME__/", "~/"] where relative.hasPrefix(prefix) {
      relative = String(relative.dropFirst(prefix.count))
      wasHomeAnchored = true
    }
    if relative.hasPrefix("/Users/") {
      let components = relative.split(separator: "/").map(String.init)
      relative = components.dropFirst(2).joined(separator: "/")
      wasHomeAnchored = true
    }
    guard wasHomeAnchored else { return relative }  // e.g. /Applications
    if relative.isEmpty { return "~" }
    let components = relative.split(separator: "/")
    return components.count == 1 ? String(components[0]) : "~/" + relative
  }

  /// Command display names skip the plumbing (run-quiet.sh, osascript…) and
  /// show the script that actually does the work, plus its first argument:
  /// `osascript ~/bin/web-jump.applescript github.com` → `web-jump github.com`.
  static func commandDisplayName(_ value: String) -> String {
    let wrappers: Set<String> = ["run-quiet.sh", "osascript", "env", "sh", "zsh", "bash", "open"]
    let tokens = value.components(separatedBy: " ").filter { !$0.isEmpty }
    var script: String?
    var argument: String?
    for token in tokens {
      if token.hasPrefix("-") { continue }
      if token.hasPrefix("'") || token.hasPrefix("\"") { break }
      let base = (token as NSString).lastPathComponent
      if wrappers.contains(base) { continue }
      if script == nil {
        if token.contains("/") || base.contains(".") { script = base; continue }
        break
      }
      argument = token
      break
    }
    guard let script else { return tokens.first ?? value }
    let name = (script as NSString).deletingPathExtension
    if let argument { return "\(name) \(argument)" }
    return name
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
