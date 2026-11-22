import Foundation
import MachineSpiritKit

extension Node {
  /// Shared by the board and overlay. Preserve the kit's explicit-label /
  /// action-name priority, then give unnamed waypoints a useful identity.
  /// The graph sidecar currently stores geometry only, not names.
  var boardLabel: String {
    resolvedBoardLabel ?? (children.count == 1 ? "gate" : "group")
  }

  var interactiveCaptureLabel: String? {
    guard case .command(let command) = action else { return nil }
    let words = command.split(whereSeparator: \.isWhitespace)
    if words.contains("~/bin/screenshots/ss-sel-save.sh") { return "Save screenshot" }
    if words.contains("~/bin/screenshots/ss-sel-copy.sh") { return "Copy screenshot" }
    return nil
  }

  private var resolvedBoardLabel: String? {
    if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return label
    }
    if let interactiveCaptureLabel { return interactiveCaptureLabel }
    if action != nil {
      var unlabeled = self
      unlabeled.label = nil
      let name = unlabeled.displayName
      if !name.isEmpty { return name }
    }
    // Only inherit along an unambiguous continuation. Never name a branch
    // after an arbitrarily selected descendant.
    if children.count == 1, let name = children[0].resolvedBoardLabel { return name }
    let keys = id.split(separator: "/").dropFirst()
    if key != nil, !keys.isEmpty { return keys.joined(separator: "-") }
    return nil
  }

  var overlayLabel: String {
    let name = boardLabel
    return name.count > 22 ? String(name.prefix(21)) + "…" : name
  }
}
