import AppKit
import Foundation
import MachineSpiritKit
import Observation

enum FocusedPane: Hashable {
  case directory
  case graph
  case ledger
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

  /// Movement energy: rigid while the hand moves, then the lines flex in
  /// proportion to how hard the board was flung — smooth, never stepping.
  var flowEnergy: Double = 0

  func disturb(_ delta: CGSize = .zero) {
    lastDisturbance = Date()
    let magnitude = Double(hypot(delta.width, delta.height))
    flowEnergy = min(1, flowEnergy * 0.75 + magnitude / 60)
  }

  /// ⌘-click multi-selection for group drags; rubber-band select fills it.
  var multiSelection: Set<String> = []

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

      // A focused text field (the pen's form) owns the keyboard outright —
      // even Tab, which moves between its fields. The field editor is an
      // NSText subclass; the popover being key means checking ITS window.
      if event.window?.firstResponder is NSText
        || NSApp.keyWindow?.firstResponder is NSText
      {
        return event
      }

      // Tab cycles panes FIRST — even out of the terminal, or sheol would
      // trap the keyboard forever.
      if event.keyCode == 48, modifiers.isEmpty {
        switch self.focusedPane {
        case .directory: self.focusedPane = .graph
        case .graph: self.focusedPane = self.ledgerOpen ? .ledger : .directory
        case .ledger: self.focusedPane = .directory
        }
        if self.focusedPane != .ledger,
          let responder = NSApp.keyWindow?.firstResponder,
          String(describing: type(of: responder)).contains("TerminalView")
        {
          NSApp.keyWindow?.makeFirstResponder(nil)
        }
        return nil
      }

      // The embedded ledger is a real terminal: when it holds focus, every
      // other key belongs to IT (walking would otherwise eat j/k/r/d/q).
      if let responder = NSApp.keyWindow?.firstResponder,
        String(describing: type(of: responder)).contains("TerminalView")
      {
        return event
      }

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

  /// Unfold the path to the current selection — and the selection itself,
  /// so a selected parent shows its children without another click.
  func revealSelectionInTree() {
    guard let selectedNodeID else { return }
    expandedIDs.formUnion(Self.ancestorIDs(of: selectedNodeID))
    expandedIDs.insert(selectedNodeID)
    expandedIDs.insert("root")
  }

  // MARK: - Dragged node positions (the sidecar earns its keep)

  /// World-space overrides for user-dragged nodes, persisted via the
  /// GraphViewState sidecar in Application Support. These are the ACTIVE
  /// layout's overrides — which named layout they belong to is `layoutMode`.
  var nodeOverrides: [String: GraphLayout.Position] = [:]

  /// The two named layouts. `hand` is the owner's arrangement, persisted in
  /// the sidecar as its own entry; `radial` is the computed mandala — never
  /// stored, always recomputable. Switching never destroys either.
  enum LayoutMode: String {
    case radial, hand
  }

  var layoutMode: LayoutMode = .radial

  /// The persisted hand arrangement (kept even while radial is active).
  @ObservationIgnored private var handLayout: [String: GraphLayout.Position] = [:]

  /// Whether a hand layout exists to toggle to.
  var hasHandLayout: Bool { !handLayout.isEmpty || (layoutMode == .hand && !nodeOverrides.isEmpty) }

  /// Switch layouts without destroying either: leaving hand captures its
  /// edits; leaving radial discards its scratch drags (radial's defining
  /// property is that it is recomputable — "sort" clears the same scratch).
  func setLayoutMode(_ mode: LayoutMode) {
    guard mode != layoutMode else { return }
    if layoutMode == .hand { handLayout = nodeOverrides }
    layoutMode = mode
    nodeOverrides = mode == .hand ? handLayout : [:]
    saveSidecar()
    disturb()
  }

  /// Wakes the canvas when an async icon/favicon arrives.
  var iconEpoch = 0

  // MARK: - The fired ping (#36): the board answers the keyboard

  /// #29 — every effect is a parameter set with an off switch, so the
  /// future settings pane is mechanical.
  struct FirePulseKnobs {
    var enabled = true
    /// Seconds for the wave front to travel center → fired node.
    var duration: Double = 1.25
    /// Seconds the arrival flash and trace linger take to fade.
    var tail: Double = 0.9
    /// Peak added brightness of the wave (0…1).
    var brightness: Double = 1.0
  }

  /// One bind execution, as the board renders it: the lit route from the
  /// center to the fired node, and when it fired.
  struct BindFire {
    let route: [String]
    let stamp: Date
  }

  var fireKnobs = FirePulseKnobs()
  var bindFire: BindFire?
  @ObservationIgnored private var bindFireCleanup: Task<Void, Never>?

  /// Receives the fork's `machinespirit://fired?path=s/s/w/s` ping.
  /// `path` is the slash-joined key sequence from the leader. Unknown or
  /// stale paths are ignored in silence — the ping must never break
  /// anything, on either side of the wire.
  func fireBind(atPath path: String) {
    guard fireKnobs.enabled, let model = displayModel else { return }
    let keys = path.hasPrefix("root")
      ? path.split(separator: "/").dropFirst()
      : path.split(separator: "/")[...]
    guard !keys.isEmpty else { return }
    var route = [model.id]
    var current = model
    for key in keys {
      guard let child = current.children.first(where: { $0.key == String(key) }) else { return }
      route.append(child.id)
      current = child
    }
    bindFire = BindFire(route: route, stamp: Date())
    disturb()
    bindFireCleanup?.cancel()
    let lifetime = fireKnobs.duration + fireKnobs.tail + 0.1
    bindFireCleanup = Task { [weak self] in
      try? await Task.sleep(for: .seconds(lifetime))
      guard let self, !Task.isCancelled else { return }
      self.bindFire = nil
    }
  }

  // MARK: - The pen (6b): the app writes the live config

  /// One completed write, as the footer tells it: the node-level summary
  /// (`+ root/g/n`) and where the pre-write backup went.
  struct PenMark {
    let lines: [String]
    let backupPath: String
  }

  var penMark: PenMark?
  var penError: String?
  @ObservationIgnored private var penFadeTask: Task<Void, Never>?

  /// Where the + button aims: the selection when it's a pure group,
  /// otherwise the selection's parent group; no selection targets the root.
  /// Nil only when there's no model (or the selection is exhibit-only).
  var penTargetGroupID: String? {
    guard let model = displayModel else { return nil }
    guard let id = selectedNodeID, id.hasPrefix("root"),
      let node = model.node(withID: id)
    else { return model.id }
    if node.action == nil { return node.id }
    guard let slash = id.lastIndex(of: "/") else { return model.id }
    return String(id[id.startIndex..<slash])
  }

  /// What the − button may strike: a selected leaf bind in the real config
  /// — never the root, never a group, never the unbound exhibit.
  var penRemovableID: String? {
    guard let id = selectedNodeID, id.hasPrefix("root/"),
      let node = displayModel?.node(withID: id), node.children.isEmpty
    else { return nil }
    return id
  }

  func penAdd(key: String, label: String?, type: String, value: String) {
    guard let model, let parentID = penTargetGroupID else { return }
    do {
      let next = try model.insertingLeaf(
        key: key, label: label, action: .from(type: type, value: value),
        underGroupID: parentID)
      try inscribe(next)
      selectedNodeID = parentID + "/" + key
      revealSelectionInTree()
      // The board celebrates its own first written bind: pulse the route.
      fireBind(atPath: parentID + "/" + key)
    } catch {
      penFail(error)
    }
  }

  func penRemove(id: String) {
    guard let model else { return }
    do {
      let next = try model.removingLeaf(id: id)
      try inscribe(next)
      if selectedNodeID == id { stepUp() }
    } catch {
      penFail(error)
    }
  }

  /// The one gate every pen stroke passes: ConfigWriter's full ritual
  /// against the live config, then a re-import of the written truth —
  /// the board never trusts its own memory of what it wrote.
  private func inscribe(_ next: Node) throws {
    let report = try ConfigWriter().write(next, to: LeaderKeyImporter.liveConfigURL)
    communeWithLiveConfig()
    penError = nil
    penMark = PenMark(lines: report.summary, backupPath: report.backupPath)
    disturb()
    penFade(after: 10)
  }

  private func penFail(_ error: Error) {
    penError = "\(error)"
    penMark = nil
    penFade(after: 14)
  }

  private func penFade(after seconds: Double) {
    penFadeTask?.cancel()
    penFadeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard let self, !Task.isCancelled else { return }
      self.penMark = nil
      self.penError = nil
    }
  }

  /// The in-app sheol ledger pane (SwiftTerm).
  var ledgerOpen = false

  private static var sidecarURL: URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MachineSpirit", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("graph-view.json")
  }

  func loadSidecar() {
    // The whole graph state survives relaunch: dragged positions AND the
    // viewport itself.
    if let data = try? Data(contentsOf: Self.sidecarURL),
      let saved = try? GraphViewState.load(from: data)
    {
      nodeOverrides = saved.nodes.mapValues { .init(x: $0.x, y: $0.y) }
      if let stored = saved.layouts?["hand"] {
        handLayout = stored.mapValues { .init(x: $0.x, y: $0.y) }
        layoutMode = LayoutMode(rawValue: saved.activeLayout ?? "") ?? .hand
      } else if saved.activeLayout == nil, !saved.nodes.isEmpty {
        // Pre-layout sidecar: its overrides ARE the owner's arrangement.
        // Migrate them to the named hand layout; nothing is lost.
        handLayout = nodeOverrides
        layoutMode = .hand
      } else {
        layoutMode = LayoutMode(rawValue: saved.activeLayout ?? "") ?? .radial
      }
      if saved.zoom > 0 {
        zoom = min(max(saved.zoom, minZoom), maxZoom)
        pan = CGSize(width: saved.panX, height: saved.panY)
      }
    }
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.saveSidecar()
        self?.shutdown()
      }
    }
  }

  func shutdown() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
    if let terminationObserver {
      NotificationCenter.default.removeObserver(terminationObserver)
      self.terminationObserver = nil
    }
    glideTask?.cancel()
    sheolPollTask?.cancel()
    bindFireCleanup?.cancel()
    penFadeTask?.cancel()
  }

  func saveSidecar() {
    // Editing the active hand layout keeps the named entry current.
    if layoutMode == .hand { handLayout = nodeOverrides }
    var saved = GraphViewState(zoom: zoom, panX: pan.width, panY: pan.height)
    saved.nodes = nodeOverrides.mapValues { .init(x: $0.x, y: $0.y) }
    saved.activeLayout = layoutMode.rawValue
    if !handLayout.isEmpty {
      saved.layouts = ["hand": handLayout.mapValues { .init(x: $0.x, y: $0.y) }]
    }
    if let data = try? saved.data() {
      try? data.write(to: Self.sidecarURL, options: .atomic)
    }
  }

  /// Wipe the saved hand arrangement for good and land on radial — the
  /// guarded, deliberate version of what the old sort did by accident.
  /// Only reachable through the confirm dialog.
  func resetHandLayout() {
    handLayout = [:]
    nodeOverrides = [:]
    layoutMode = .radial
    saveSidecar()
    disturb()
  }

  /// "sort" — return to the computed radial order. In hand mode this is
  /// just a mode switch (the hand arrangement is captured, never wiped);
  /// in radial mode it clears the scratch drags.
  func clearOverrides() {
    if layoutMode == .hand {
      handLayout = nodeOverrides
      layoutMode = .radial
    }
    nodeOverrides = [:]
    saveSidecar()
    disturb()
  }

  /// Import the live Leader Key config — the runtime source of truth.
  /// Reading is free; WRITING happens only through `inscribe` (the pen),
  /// which is to say only through ConfigWriter's full gate-backup-validate
  /// ritual. Nothing else in the app may touch the live file.
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
  @ObservationIgnored private var terminationObserver: NSObjectProtocol?

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
