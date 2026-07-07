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
  /// unfold the path to the selection. "root" is the leader-key parent row
  /// (one per hotkey; more leaders are a future concern), open by default.
  var expandedIDs: Set<String> = ["root"]

  /// The directory pane collapses to give the board the whole window.
  var directoryCollapsed = false

  // MARK: - Graph viewport (shared so keys, slider, and gestures agree)

  var zoom: CGFloat = 0.4  // opens on the skeleton bands; walking zooms in
  var pan: CGSize = .zero
  // The floor keeps the first graph findable at extreme zoom-out while
  // leaving room for a workspace of future leader graphs.
  let minZoom: CGFloat = 0.08
  let maxZoom: CGFloat = 6

  /// The graph pane's frame in window coordinates (top-left origin), kept
  /// fresh by GraphView so the scroll monitor can scope itself to it.
  @ObservationIgnored var graphFrame: CGRect = .zero

  /// Reference instant for the boot/refresh growth animation — traces grow
  /// out of the center toward the rim, the directory cascades in.
  var bootStamp = Date()

  /// The lines stir when the viewport moves and settle to perfect stillness
  /// (no idle jitter — a calm board pauses its render clock entirely).
  /// Observed so views wake the clock the instant something moves.
  var lastDisturbance = Date.distantPast

  /// Direction and vigor of the latest movement — the traces trail against
  /// it like weed in a current, then relax. Blended so bursts feel fluid.
  var flow: CGSize = .zero

  func disturb(_ delta: CGSize = .zero) {
    lastDisturbance = Date()
    flow = CGSize(
      width: max(-30, min(30, flow.width * 0.6 + delta.width * 0.5)),
      height: max(-30, min(30, flow.height * 0.6 + delta.height * 0.5)))
  }

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
        let previous = self.pan
        self.pan = CGSize(
          width: fromPan.width + (target.width - fromPan.width) * eased,
          height: fromPan.height + (target.height - fromPan.height) * eased)
        self.zoom = fromZoom + (toZoom - fromZoom) * eased
        self.disturb(
          CGSize(
            width: self.pan.width - previous.width,
            height: self.pan.height - previous.height))
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
        case "r": self.refresh(); return nil
        case "=", "+": self.zoomKeyed(by: 1.25); return nil
        case "-": self.zoomKeyed(by: 1 / 1.25); return nil
        default: return event
        }
      }
      guard modifiers.isEmpty else { return event }

      switch event.keyCode {
      case 48:  // tab
        self.focusedPane = self.focusedPane == .directory ? .graph : .directory
        return nil
      case 53:  // esc — the walk returns home: root centered, default view
        self.selectedNodeID = nil
        self.glide(toPan: .zero, zoom: 0.4)
        return nil
      case 51:  // delete — one step back up
        self.stepUp()
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
  /// current selection's children. At the end of a branch you STAY — more
  /// keys do nothing; Esc (or dead-space click) returns to the root.
  private func walk(typed: String) -> Bool {
    guard let root = displayModel else { return false }
    let anchor = selectedNodeID.flatMap { root.node(withID: $0) } ?? root
    if let hit = match(typed, in: anchor) {
      selectedNodeID = hit.id
      revealSelectionInTree()
      return true
    }
    // Consume the key anyway when a node is selected — a mistyped key at
    // the end of a chain shouldn't leak into the system.
    return selectedNodeID != nil
  }

  /// ⌘= / ⌘- : zoom anchored on the selection when there is one.
  private func zoomKeyed(by factor: CGFloat) {
    let newZoom = min(max(zoom * factor, minZoom), maxZoom)
    if let id = selectedNodeID, let model = displayModel,
      let position = RadialLayout.layout(root: model).positions[id]
    {
      glide(
        toPan: CGSize(width: -position.x * newZoom, height: -position.y * newZoom),
        zoom: newZoom)
    } else {
      zoom = newZoom
    }
  }

  // MARK: - Refresh, with something to feel

  var refreshFlashing = false

  func refresh() {
    communeWithLiveConfig()
    Task { spirits = await SheolService.list() }
    refreshFlashing = true
    bootStamp = Date()  // regrow the traces, re-cascade the directory
    disturb()
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1600))
      self?.refreshFlashing = false
    }
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

  // MARK: - Scroll: wheel zooms at the cursor, trackpad pans, ⌘ always zooms

  @ObservationIgnored private var scrollMonitor: Any?

  func installScrollMonitor() {
    guard scrollMonitor == nil else { return }
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
      [weak self] event in
      guard let self, let window = event.window,
        let contentHeight = window.contentView?.bounds.height
      else { return event }
      // Window coords are bottom-left; SwiftUI global frames are top-left.
      let point = CGPoint(
        x: event.locationInWindow.x,
        y: contentHeight - event.locationInWindow.y)
      guard self.graphFrame.contains(point) else { return event }

      self.cancelGlide()
      let cursorOffset = CGSize(
        width: point.x - self.graphFrame.midX,
        height: point.y - self.graphFrame.midY)
      let commandHeld = event.modifierFlags.contains(.command)
      let isTrackpad = event.hasPreciseScrollingDeltas

      if commandHeld || !isTrackpad {
        // Zoom, anchored so the world point under the cursor stays put.
        let factor = 1 + (isTrackpad ? 0.01 : 0.06) * event.scrollingDeltaY
        self.zoom(at: cursorOffset, by: factor)
        self.disturb()
      } else {
        self.pan.width += event.scrollingDeltaX
        self.pan.height += event.scrollingDeltaY
        self.disturb(
          CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
      }
      return nil
    }
  }

  private func zoom(at cursorOffset: CGSize, by factor: CGFloat) {
    let newZoom = min(max(zoom * factor, minZoom), maxZoom)
    guard newZoom != zoom else { return }
    // Keep the world point under the cursor stationary through the zoom.
    let worldX = (cursorOffset.width - pan.width) / zoom
    let worldY = (cursorOffset.height - pan.height) / zoom
    pan = CGSize(
      width: cursorOffset.width - worldX * newZoom,
      height: cursorOffset.height - worldY * newZoom)
    zoom = newZoom
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
    expandedIDs.insert("root")
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
  ///
  /// Owner ruling (2026-07-06): live sessions do NOT appear inside the
  /// config graph — that surface is for binds and commands. Spirits get
  /// their own ledger surface later (design cache #15); until then the
  /// footer carries the quiet nag and the TUI remains the ledger.
  var spirits: [Spirit] = []

  @ObservationIgnored private var sheolPollTask: Task<Void, Never>?

  /// What the views render. (Identical to `model` since the owner ruled
  /// spirits out of the config graph; kept as the views' single entry
  /// point for whatever display-only layers come later.)
  var displayModel: Node? { model }

  /// A second leader graph beside the first — the multi-leader future made
  /// visible. HONESTLY UNBOUND: mouse button 4 triggers nothing yet; the
  /// exhibit says so on its face. Configurable leaders are a later step.
  static let auxLeader = Node(
    id: "mb4",
    key: "M4",
    label: "mouse button 4 · unbound example",
    children: [
      Node(
        id: "mb4/q",
        key: "q",
        label: "open Spotlight search",
        action: .other(type: "unbound", value: "spotlight")),
      Node(
        id: "mb4/e",
        key: "e",
        label: "open wallpaper settings",
        action: .other(type: "unbound", value: "wallpaper")),
    ],
    hadChildrenArray: true
  )

  func startSheolPolling() {
    guard sheolPollTask == nil else { return }
    sheolPollTask = Task { [weak self] in
      while !Task.isCancelled {
        let spirits = await SheolService.list()
        guard let self else { return }
        if self.spirits != spirits { self.spirits = spirits }
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }
}
