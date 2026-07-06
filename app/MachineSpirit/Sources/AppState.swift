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
