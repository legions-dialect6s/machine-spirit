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

  // Owner-specified node palette (2026-07-06):
  /// Rectangle / window-tiling commands.
  static let mint = Color(red: 174 / 255, green: 222 / 255, blue: 203 / 255)
  /// Finder / folder opens.
  static let ice = Color(red: 217 / 255, green: 241 / 255, blue: 254 / 255)
  /// Plain terminal commands — a harder terminal green than the group glow.
  static let terminal = Color(red: 0.3, green: 0.95, blue: 0.45)
  static let url = Color(red: 0.65, green: 0.7, blue: 1.0)

  /// The node's identity color — groups glow phosphor, each action type
  /// wears its own; app nodes are tinted by their icon (IconStore overrides
  /// this in the graph).
  static func nodeColor(for node: Node) -> Color {
    guard let action = node.action else { return phosphor }
    if node.isDual { return magenta }
    if action.windowAction != nil { return mint }
    switch action {
    case .application: return phosphor
    case .folder: return ice
    case .command: return terminal
    case .url: return url
    case .other: return ash
    }
  }

  static func badgeText(for node: Node) -> String {
    guard let action = node.action else { return "GRP" }
    if action.windowAction != nil { return "WIN" }
    switch action {
    case .application: return "APP"
    case .command: return "CMD"
    case .folder: return "DIR"
    case .url: return "URL"
    case .other(let type, _): return String(type.prefix(3)).uppercased()
    }
  }

  static func badgeColor(for node: Node) -> Color {
    guard node.action != nil else { return phosphorDim }
    return nodeColor(for: node)
  }
}
