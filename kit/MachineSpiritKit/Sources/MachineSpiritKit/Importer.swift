import Foundation

public enum ImportError: Error, Equatable, CustomStringConvertible {
  case rootIsNotAnObject
  case malformedChild(path: String)

  public var description: String {
    switch self {
    case .rootIsNotAnObject:
      return "Config root must be a JSON object"
    case .malformedChild(let path):
      return "Non-object entry in actions array at \(path)"
    }
  }
}

/// Imports a Leader Key `config.json` into the node graph, losslessly.
///
/// - Known fields (`key`, `type`, `label`, `value`, `actions`) lift into
///   typed storage; everything else lands in `Node.extras` verbatim —
///   including fields Leader Key knows but this model doesn't (`iconPath`)
///   and fields nobody knows yet.
/// - Values are opaque strings: `__HOME__` templating and tildes are never
///   expanded; the model executes nothing in Phase 1.
/// - Empty configs (`{}`, empty `actions`) import as an empty graph.
/// - The runtime source of truth is the live config at
///   `~/Library/Application Support/Leader Key/config.json` — read-only.
public struct LeaderKeyImporter {
  public let probe: AvailabilityProbe

  public init(probe: AvailabilityProbe = FileSystemProbe()) {
    self.probe = probe
  }

  /// Default live-config location (the runtime source of truth, read-only).
  public static var liveConfigURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Leader Key/config.json")
  }

  public func importConfig(from data: Data) throws -> Node {
    let json = try JSONDecoder().decode(JSONValue.self, from: data)
    guard let rootObject = json.objectValue else {
      throw ImportError.rootIsNotAnObject
    }
    return try node(from: rootObject, id: "root")
  }

  public func importConfig(at url: URL) throws -> Node {
    try importConfig(from: try Data(contentsOf: url))
  }

  private func node(from object: [String: JSONValue], id: String) throws -> Node {
    let key = object["key"]?.stringValue
    let label = object["label"]?.stringValue
    let typeString = object["type"]?.stringValue
    let valueString = object["value"]?.stringValue
    let actionsArray = object["actions"]?.arrayValue

    // Only fields actually lifted are consumed — a known field carrying an
    // unexpected JSON type stays in extras instead of being dropped.
    var consumed: Set<String> = []
    if key != nil { consumed.insert("key") }
    if label != nil { consumed.insert("label") }
    if actionsArray != nil { consumed.insert("actions") }

    // An action payload exists when a non-group type arrives with a value.
    // A non-group type WITHOUT a value is malformed by LK's schema; we leave
    // both fields in extras rather than invent a value — still lossless.
    var action: ActionPayload?
    var hadExplicitType = false
    if let typeString {
      if typeString == "group" {
        hadExplicitType = true
        consumed.insert("type")
      } else if let valueString {
        action = .from(type: typeString, value: valueString)
        hadExplicitType = true
        consumed.formUnion(["type", "value"])
      }
    }

    // Children decode for ANY node type — the model holds group+action
    // duality natively even though LK's own configs never produce it.
    var children: [Node] = []
    var usedIDs: Set<String> = []
    if let actionsArray {
      for (index, element) in actionsArray.enumerated() {
        guard let childObject = element.objectValue else {
          throw ImportError.malformedChild(path: id)
        }
        var childID = id + "/" + (childObject["key"]?.stringValue ?? "#\(index)")
        var bump = 1
        while usedIDs.contains(childID) {
          bump += 1
          childID = id + "/" + (childObject["key"]?.stringValue ?? "#\(index)") + "~\(bump)"
        }
        usedIDs.insert(childID)
        children.append(try node(from: childObject, id: childID))
      }
    }

    let extras = object.filter { !consumed.contains($0.key) }

    return Node(
      id: id,
      key: key,
      label: label,
      action: action,
      children: children,
      extras: extras,
      status: Availability.status(of: action, probe: probe),
      hadExplicitType: hadExplicitType,
      hadChildrenArray: actionsArray != nil
    )
  }
}
