import AppKit
import Foundation
import MachineSpiritKit
import Observation

enum ViewMode: Hashable {
  case tree
  case graph
}

/// The one source of truth. Selection lives here and ONLY here — the tree
/// and the graph are both projections of this state, which is what makes
/// tab-switching carry the selection across worlds for free.
@Observable
@MainActor
final class AppState {
  var model: Node?
  var selectedNodeID: String?
  var viewMode: ViewMode = .tree
  var importError: String?

  /// Disclosure state for the tree — programmatic so landing can unfold
  /// the path to the selection.
  var expandedIDs: Set<String> = []

  func crossBetweenWorlds() {
    viewMode = viewMode == .tree ? .graph : .tree
  }

  /// Tab crosses between worlds — tree ⇄ graph, one selection carried.
  /// A local NSEvent monitor beats .onKeyPress here: it works regardless of
  /// which subview holds focus, and there are no text fields to starve yet.
  /// The token MUST be retained — an unheld monitor deallocates immediately.
  @ObservationIgnored private var tabMonitor: Any?

  func installTabMonitor() {
    guard tabMonitor == nil else { return }
    tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let tabKeyCode: UInt16 = 48
      guard event.keyCode == tabKeyCode,
        event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
      else { return event }
      self?.crossBetweenWorlds()
      return nil
    }
  }

  /// Ancestor ids of a structural path id: `root/g/p` → `root/g`
  /// (root itself excluded — the tree lists root's children at top level).
  static func ancestorIDs(of id: String) -> [String] {
    let parts = id.split(separator: "/").map(String.init)
    guard parts.count > 2 else { return [] }
    return (2..<parts.count).map { parts[0..<$0].joined(separator: "/") }
  }

  /// Unfold the path to the current selection so its row is visible.
  func revealSelectionInTree() {
    guard let selectedNodeID else { return }
    expandedIDs.formUnion(Self.ancestorIDs(of: selectedNodeID))
  }

  /// Import the live Leader Key config — the runtime source of truth,
  /// read-only, always (Phase-1 law: the app never writes the live system).
  func communeWithLiveConfig() {
    do {
      model = try LeaderKeyImporter().importConfig(at: LeaderKeyImporter.liveConfigURL)
      importError = nil
    } catch {
      model = nil
      importError = "the spirits are silent: \(error)"
    }
  }

  var nodeCount: Int { model.map { $0.totalCount - 1 } ?? 0 }
}
