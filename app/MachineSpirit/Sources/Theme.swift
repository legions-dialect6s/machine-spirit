import MachineSpiritKit
import SwiftUI

/// The register: near-black ground, phosphor-green primary, magenta reserved
/// for sheol/necromantic accents. Rhymes with assets/icon.png.
enum Theme {
  static let ground = Color(red: 0.016, green: 0.031, blue: 0.024)
  static let groundRaised = Color(red: 0.035, green: 0.062, blue: 0.048)
  static let phosphor = Color(red: 0.29, green: 1.0, blue: 0.55)
  static let phosphorDim = Color(red: 0.18, green: 0.55, blue: 0.33)
  /// Reserved for sheol / necromantic accents (duality wears it too — the
  /// centerpiece dual node IS sheol). Everything mundane stays off magenta.
  static let magenta = Color(red: 1.0, green: 0.27, blue: 0.72)
  static let ash = Color(white: 0.52)
  static let ice = Color(red: 0.5, green: 0.93, blue: 0.9)

  /// Synthetic sheol nodes (spirits and their verbs) wear the necromantic
  /// accent. Display-only — these nodes never serialize.
  static func isNecromantic(_ node: Node) -> Bool {
    node.id.contains("/spirit:")
  }

  static func badgeText(for node: Node) -> String {
    guard let action = node.action else { return isNecromantic(node) ? "⌁" : "GRP" }
    if action.windowAction != nil { return "WIN" }
    switch action {
    case .application: return "APP"
    case .command: return "CMD"
    case .folder: return "DIR"
    case .url: return "URL"
    case .other(AppState.reviveType, _): return "REV"
    case .other(AppState.banishType, _): return "BAN"
    case .other(let type, _): return String(type.prefix(3)).uppercased()
    }
  }

  static func badgeColor(for node: Node) -> Color {
    guard let action = node.action else { return isNecromantic(node) ? magenta : phosphorDim }
    if action.windowAction != nil { return ice }
    switch action {
    case .application: return phosphor
    case .command: return Color(red: 0.55, green: 0.9, blue: 1.0)
    case .folder: return Color(red: 0.95, green: 0.8, blue: 0.35)
    case .url: return Color(red: 0.65, green: 0.7, blue: 1.0)
    case .other(AppState.reviveType, _): return phosphor
    case .other(AppState.banishType, _): return magenta
    case .other: return ash
    }
  }
}
