import AppKit
import Foundation
import MachineSpiritKit
import Observation

enum FocusedPane: Hashable {
  case directory
  case graph
}

/// The one source of truth. Selection lives here and ONLY here — the
/// directory and the node graph render side by side as projections of it,
/// so walking with the keyboard moves both at once.
@Observable
@MainActor
final class AppState {
  var model: Node?
  var selectedNodeID: String?
  var focusedPane: FocusedPane = .graph
  var importError: String?

  /// Disclosure state for the directory — programmatic so navigation can
  /// unfold the path to the selection.
  var expandedIDs: Set<String> = []

  // MARK: - Graph viewport (shared so keys, slider, and gestures agree)

  var zoom: CGFloat = 0.4  // opens on the skeleton bands; walking zooms in
  var pan: CGSize = .zero
  let minZoom: CGFloat = 0.03
  let maxZoom: CGFloat = 6

  @ObservationIgnored private var glideTask: Task<Void, Never>?

  /// Organic lerp of the graph viewport — smoothstep, ~a third of a second,
  /// the win-lerp lineage. Direct gestures cancel it.
  func glide(toPan target: CGSize, zoom targetZoom: CGFloat? = nil) {
    glideTask?.cancel()
    let fromPan = pan
    let fromZoom = zoom
    let toZoom = min(max(targetZoom ?? zoom, minZoom), maxZoom)
    glideTask = Task { [weak self] in
      let steps = 22
      for step in 1...steps {
        guard let self, !Task.isCancelled else { return }
        let t = Double(step) / Double(steps)
        let eased = t * t * (3 - 2 * t)  // smoothstep
        self.pan = CGSize(
          width: fromPan.width + (target.width - fromPan.width) * eased,
          height: fromPan.height + (target.height - fromPan.height) * eased)
        self.zoom = fromZoom + (toZoom - fromZoom) * eased
        try? await Task.sleep(for: .milliseconds(15))
      }
    }
  }

  func cancelGlide() { glideTask?.cancel() }

  // MARK: - Keyboard: walk the graph like Leader Key itself

  /// One retained local NSEvent monitor handles every key (the token MUST
  /// be held — an unretained monitor deallocates immediately; that bug
  /// already bit once):
  ///   letters  walk the binds (1 → 1 → first-third), both views follow
  ///   esc      back to the root (clear selection)
  ///   ⌫        step up one level
  ///   ⏎        strike a selected sheol verb (revive / arm the ward)
  ///   tab      switch focused pane
  ///   ⌘r       refresh (re-import)
  ///   ⌘= / ⌘-  zoom the graph
  @ObservationIgnored private var keyMonitor: Any?

  func installKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

      if modifiers == .command {
        switch event.charactersIgnoringModifiers {
        case "r": self.communeWithLiveConfig(); return nil
        case "=", "+": self.zoom = min(self.zoom * 1.25, self.maxZoom); return nil
        case "-": self.zoom = max(self.zoom / 1.25, self.minZoom); return nil
        default: return event
        }
      }
      guard modifiers.isEmpty else { return event }

      switch event.keyCode {
      case 48:  // tab
        self.focusedPane = self.focusedPane == .directory ? .graph : .directory
        return nil
      case 53:  // esc — the walk returns to the root
        self.selectedNodeID = nil
        return nil
      case 51:  // delete — one step back up
        self.stepUp()
        return nil
      case 36:  // return — strike a sheol verb
        if let id = self.selectedNodeID, let node = self.displayModel?.node(withID: id) {
          _ = self.strikeSheolNode(node)
        }
        return nil
      default:
        break
      }

      if let typed = event.charactersIgnoringModifiers, typed.count == 1,
        typed.rangeOfCharacter(from: .alphanumerics.union(.punctuationCharacters).union(.symbols))
          != nil,
        self.walk(typed: typed)
      {
        return nil
      }
      return event
    }
  }

  /// Leader Key's grammar, in both views: match the typed key against the
  /// current selection's children; a leaf with no match restarts from root.
  private func walk(typed: String) -> Bool {
    guard let root = displayModel else { return false }
    let anchor = selectedNodeID.flatMap { root.node(withID: $0) } ?? root
    if let hit = match(typed, in: anchor) ?? match(typed, in: root) {
      selectedNodeID = hit.id
      revealSelectionInTree()
      return true
    }
    return false
  }

  private func match(_ typed: String, in node: Node) -> Node? {
    node.children.first { $0.key == typed }
      ?? node.children.first { $0.key?.lowercased() == typed.lowercased() }
  }

  private func stepUp() {
    guard let id = selectedNodeID, let slash = id.lastIndex(of: "/") else { return }
    let parent = String(id[id.startIndex..<slash])
    selectedNodeID = parent == "root" ? nil : parent
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
      importError = "could not read the live config: \(error)"
    }
  }

  var nodeCount: Int { model.map { $0.totalCount - 1 } ?? 0 }

  // MARK: - sheol, live

  /// Wandering spirits from the last poll (detached tmux sessions).
  var spirits: [Spirit] = []

  /// The ◆◆◇ ward: banish arms per-node and decays after ~2s untouched.
  var banishArm: (nodeID: String, count: Int, at: Date)?

  @ObservationIgnored private var sheolPollTask: Task<Void, Never>?

  static let spiritType = "spirit"
  static let reviveType = "sheol-revive"
  static let banishType = "sheol-banish"

  /// What the views render: the imported config with the sheol bind grown
  /// into a living node while spirits wander. Conditional visibility —
  /// when sheol is empty the bind stays its plain imported self.
  var displayModel: Node? {
    guard let model else { return nil }
    let wanderers = spirits.filter(\.isWandering)
    guard !wanderers.isEmpty, let sheolID = sheolBindID(in: model) else { return model }
    return graft(into: model, at: sheolID, wanderers: wanderers)
  }

  /// The bind that opens the full ledger (`tmux-sheol-open.sh`) is THE
  /// sheol node — found by its value, not a hardcoded key path.
  private func sheolBindID(in root: Node) -> String? {
    if let action = root.action, action.value.contains("tmux-sheol-open") {
      return root.id
    }
    for child in root.children {
      if let found = sheolBindID(in: child) { return found }
    }
    return nil
  }

  private func graft(into node: Node, at id: String, wanderers: [Spirit]) -> Node {
    var node = node
    if node.id == id {
      // Group+action duality on display: the ledger-opening action keeps
      // its core; the wandering spirits give it the ring. Both lit.
      node.children = wanderers.map { spirit in
        let base = "\(id)/spirit:\(spirit.name)"
        let armed = banishArm?.nodeID == "\(base)/banish" ? banishArm!.count : 0
        let ward = (0..<3).map { $0 < armed ? "◆" : "◇" }.joined()
        return Node(
          id: base,
          key: "⌁",
          label: "\(spirit.name) · \(spirit.command) · quiet \(spirit.quietFor)",
          children: [
            Node(
              id: "\(base)/revive",
              key: "r",
              label: "revive — a new body",
              action: .other(type: Self.reviveType, value: spirit.name)),
            Node(
              id: "\(base)/banish",
              key: "d",
              label: "banish \(ward) — exile forever",
              action: .other(type: Self.banishType, value: spirit.name)),
          ],
          extras: [:],
          hadExplicitType: false,
          hadChildrenArray: true
        )
      }
      node.hadChildrenArray = true
      return node
    }
    node.children = node.children.map { graft(into: $0, at: id, wanderers: wanderers) }
    return node
  }

  func startSheolPolling() {
    guard sheolPollTask == nil else { return }
    sheolPollTask = Task { [weak self] in
      while !Task.isCancelled {
        let spirits = await SheolService.list()
        guard let self else { return }
        if self.spirits != spirits { self.spirits = spirits }
        if let arm = self.banishArm, Date().timeIntervalSince(arm.at) > 2 {
          self.banishArm = nil  // the ward decays
        }
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  /// Invoked when a synthetic sheol action node is struck in either view.
  /// Returns true if the node was a sheol action (and was handled).
  func strikeSheolNode(_ node: Node) -> Bool {
    guard case .other(let type, let name) = node.action else { return false }
    switch type {
    case Self.reviveType:
      Task {
        await SheolService.revive(name)
        spirits = await SheolService.list()
      }
      return true
    case Self.banishType:
      if let arm = banishArm, arm.nodeID == node.id {
        let count = arm.count + 1
        if count >= 3 {
          banishArm = nil
          Task {
            await SheolService.exile(name)
            spirits = await SheolService.list()
          }
        } else {
          banishArm = (node.id, count, Date())
        }
      } else {
        banishArm = (node.id, 1, Date())
      }
      return true
    default:
      return false
    }
  }
}
