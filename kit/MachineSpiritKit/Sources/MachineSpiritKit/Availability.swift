import Foundation

/// Answers "is this dependency present on this machine?" — injectable so
/// tests never depend on the machine they run on.
public protocol AvailabilityProbe: Sendable {
  func pathExists(_ path: String) -> Bool
  func rectanglePresent() -> Bool
  func tmuxPresent() -> Bool
}

/// The real probe. Tilde expansion happens for the *check only* — stored
/// config values are never rewritten.
public struct FileSystemProbe: AvailabilityProbe {
  public init() {}

  public func pathExists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
  }

  public func rectanglePresent() -> Bool {
    pathExists("/Applications/Rectangle.app")
      || pathExists("/System/Volumes/Data/Applications/Rectangle.app")
  }

  public func tmuxPresent() -> Bool {
    ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
      .contains { FileManager.default.isExecutableFile(atPath: $0) }
  }
}

enum Availability {
  /// Derive a node's runtime status from its payload. Groups are always
  /// active; commands and paths are probed. `__HOME__`-templated values
  /// (repo fixtures) are honestly inert — they reference no real path.
  static func status(of payload: ActionPayload?, probe: AvailabilityProbe) -> RuntimeStatus {
    guard let payload else { return .active }

    switch payload {
    case .application(let path), .folder(let path):
      if path.contains("__HOME__") {
        return .inert(reason: "templated path (fixture import)")
      }
      return probe.pathExists(path) ? .active : .inert(reason: "missing: \(path)")

    case .command(let value):
      if payload.windowAction != nil {
        return probe.rectanglePresent()
          ? .active : .inert(reason: "Rectangle.app not installed")
      }
      if value.contains("tmux"), !probe.tmuxPresent() {
        return .inert(reason: "tmux not installed")
      }
      if let script = referencedScriptPath(in: value) {
        if script.contains("__HOME__") {
          return .inert(reason: "templated path (fixture import)")
        }
        return probe.pathExists(script) ? .active : .inert(reason: "missing: \(script)")
      }
      return .active

    case .url, .other:
      return .active
    }
  }

  /// First token in a command that looks like a home-anchored script path
  /// (`~/bin/x.sh`, `__HOME__/bin/x.applescript`, `/Users/...`). Enough for
  /// the Phase-1 probe; not a shell parser.
  static func referencedScriptPath(in command: String) -> String? {
    command
      .components(separatedBy: .whitespaces)
      .first { token in
        token.hasPrefix("~/") || token.hasPrefix("__HOME__/") || token.hasPrefix("/Users/")
      }
  }
}
