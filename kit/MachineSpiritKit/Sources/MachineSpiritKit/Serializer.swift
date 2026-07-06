import Foundation

/// Serializes the node graph back to Leader Key JSON.
///
/// The round-trip gate (Tests/RoundTripTests) holds this to canonical-JSON
/// equality with the imported source: parse both, deep-compare; array order
/// preserved, object key order irrelevant.
public enum LeaderKeySerializer {
  public static func jsonValue(from node: Node) -> JSONValue {
    var object = node.extras

    if let key = node.key { object["key"] = .string(key) }
    if let label = node.label { object["label"] = .string(label) }

    if let action = node.action {
      object["type"] = .string(action.typeString)
      object["value"] = .string(action.value)
    } else if node.hadExplicitType {
      object["type"] = .string("group")
    }

    if node.hadChildrenArray || !node.children.isEmpty {
      object["actions"] = .array(node.children.map(jsonValue(from:)))
    }

    return .object(object)
  }

  /// Rendered bytes in Leader Key's on-disk style (JSONSerialization's
  /// pretty-printed, sorted-keys `"key" : "value"` form). Round-trip diffs
  /// go to temp files in Phase 1 — the live config is never written.
  public static func data(from node: Node) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: jsonValue(from: node).foundationObject,
      options: [.prettyPrinted, .sortedKeys]
    )
  }
}
