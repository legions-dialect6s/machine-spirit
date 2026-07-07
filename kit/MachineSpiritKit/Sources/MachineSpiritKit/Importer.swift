import Foundation

public enum ImportError: Error, Equatable, CustomStringConvertible {
  case rootIsNotAnObject
  case malformedChild(path: String)
  case duplicateKey(String)

  public var description: String {
    switch self {
    case .rootIsNotAnObject:
      return "Config root must be a JSON object"
    case .malformedChild(let path):
      return "Non-object entry in actions array at \(path)"
    case .duplicateKey(let key):
      return "Duplicate key \"\(key)\" inside a single JSON object — refusing to import"
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
/// - **Losslessness boundary:** duplicate keys inside a single JSON object
///   are not representable through the JSONDecoder/dictionary path — the
///   decoder would silently keep one value and drop the rest. Leader Key's
///   own writer never emits duplicates; if one ever appears, import fails
///   loudly (`ImportError.duplicateKey`) rather than silently dropping.
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
    if let duplicate = Self.firstDuplicateObjectKey(in: data) {
      throw ImportError.duplicateKey(duplicate)
    }
    let json = try JSONDecoder().decode(JSONValue.self, from: data)
    guard let rootObject = json.objectValue else {
      throw ImportError.rootIsNotAnObject
    }
    return try node(from: rootObject, id: "root")
  }

  /// JSONDecoder keeps the FIRST of duplicate keys in an object and drops
  /// the rest — silently. A lossless importer can't allow that, so the raw
  /// bytes are scanned for within-one-object duplicates before decoding.
  /// Best-effort on malformed JSON (returns nil; the decoder then throws
  /// its own error). Keys are compared as written — `"\u{5C}u0061"` vs
  /// `"a"` would slip past, but nothing that writes configs escapes so.
  static func firstDuplicateObjectKey(in data: Data) -> String? {
    struct Frame {
      var isObject: Bool
      var seen: Set<String> = []
      var expectKey: Bool
    }
    let bytes = [UInt8](data)
    var frames: [Frame] = []
    var i = 0
    while i < bytes.count {
      switch bytes[i] {
      case UInt8(ascii: "{"):
        frames.append(Frame(isObject: true, expectKey: true))
      case UInt8(ascii: "["):
        frames.append(Frame(isObject: false, expectKey: false))
      case UInt8(ascii: "}"), UInt8(ascii: "]"):
        guard !frames.isEmpty else { return nil }
        frames.removeLast()
      case UInt8(ascii: ","):
        if frames.last?.isObject == true { frames[frames.count - 1].expectKey = true }
      case UInt8(ascii: ":"):
        if frames.last?.isObject == true { frames[frames.count - 1].expectKey = false }
      case UInt8(ascii: "\""):
        let start = i + 1
        var j = start
        while j < bytes.count, bytes[j] != UInt8(ascii: "\"") {
          j += bytes[j] == UInt8(ascii: "\\") ? 2 : 1
        }
        guard j < bytes.count else { return nil }
        if let frame = frames.last, frame.isObject, frame.expectKey {
          let key = String(decoding: bytes[start..<j], as: UTF8.self)
          if !frames[frames.count - 1].seen.insert(key).inserted { return key }
        }
        i = j
      default:
        break
      }
      i += 1
    }
    return nil
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
