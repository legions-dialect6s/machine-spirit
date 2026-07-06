import Foundation

/// A general JSON value — the unknown-field bag that makes "lossless" a
/// mechanism instead of a claim. Any config field the model doesn't lift into
/// typed storage survives import → serialize inside one of these.
public enum JSONValue: Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

extension JSONValue: Equatable {
  /// Numeric equality is value-based (`.int(1) == .number(1.0)`) so a
  /// round-trip can't fail on integer-vs-double decoding trivia.
  public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null): return true
    case let (.bool(a), .bool(b)): return a == b
    case let (.int(a), .int(b)): return a == b
    case let (.number(a), .number(b)): return a == b
    case let (.int(a), .number(b)), let (.number(b), .int(a)): return Double(a) == b
    case let (.string(a), .string(b)): return a == b
    case let (.array(a), .array(b)): return a == b
    case let (.object(a), .object(b)): return a == b
    default: return false
    }
  }
}

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

extension JSONValue {
  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  /// Foundation representation for JSONSerialization (which renders the
  /// `"key" : "value"` spacing Leader Key's own writer produces).
  public var foundationObject: Any {
    switch self {
    case .null: return NSNull()
    case .bool(let value): return value
    case .int(let value): return value
    case .number(let value): return value
    case .string(let value): return value
    case .array(let value): return value.map(\.foundationObject)
    case .object(let value): return value.mapValues(\.foundationObject)
    }
  }
}
