import Foundation

/// What a node *does* when invoked. Mirrors Leader Key's action types
/// (`application` / `url` / `command` / `folder`) plus `other` so an unknown
/// future type imports losslessly instead of crashing or being dropped.
public enum ActionPayload: Equatable, Sendable {
  case application(path: String)
  case url(String)
  case command(String)
  case folder(path: String)
  case other(type: String, value: String)

  /// The Leader Key `type` string this payload serializes back to.
  public var typeString: String {
    switch self {
    case .application: return "application"
    case .url: return "url"
    case .command: return "command"
    case .folder: return "folder"
    case .other(let type, _): return type
    }
  }

  /// The stored `value` string, always opaque and byte-identical to import.
  public var value: String {
    switch self {
    case .application(let path): return path
    case .url(let value): return value
    case .command(let value): return value
    case .folder(let path): return path
    case .other(_, let value): return value
    }
  }

  public static func from(type: String, value: String) -> ActionPayload {
    switch type {
    case "application": return .application(path: value)
    case "url": return .url(value)
    case "command": return .command(value)
    case "folder": return .folder(path: value)
    default: return .other(type: type, value: value)
    }
  }

  /// Keep window binds visually consistent across the native and Rectangle movers.
  public var windowAction: String? {
    rectangleAction ?? nativePlacement?.mode
  }

  var nativePlacement: (executable: String, mode: String)? {
    guard case .command(let value) = self else { return nil }
    var words = value.split(whereSeparator: \.isWhitespace)[...]
    if words.first?.split(separator: "/").last == "run-quiet.sh" { words = words.dropFirst() }
    guard let executable = words.first, executable.split(separator: "/").last == "ms",
      words.dropFirst().starts(with: ["win", "place"]), let mode = words.dropFirst(3).first,
      mode.first?.isLetter == true, mode.allSatisfy({ $0.isLetter || $0 == "-" })
    else { return nil }
    return (String(executable), String(mode))
  }

  var rectangleAction: String? {
    guard case .command(let value) = self else { return nil }
    guard let range = value.range(of: "rectangle://execute-action?name=") else { return nil }
    let name = value[range.upperBound...].prefix { character in
      character.isLetter || character.isNumber || character == "-" || character == "_"
    }
    return name.isEmpty ? nil : String(name)
  }
}
