import Cocoa
import Combine
import Sparkle

// machine-spirit fork: the skull menu-bar item is a "harness-fork" control
// surface — one summonable menu that folds the three tools the environment
// leans on into labeled sections: Leader Key (native), Rectangle (driven via
// its rectangle:// URL scheme) and Karabiner (status + profile via
// karabiner_cli — never rebuilt, per design cache #4). Rectangle's and
// Karabiner's own menu-bar icons are hidden so only the skull remains.
class StatusItem: NSObject, NSMenuDelegate {
  enum Appearance {
    case normal
    case active
  }

  var appearance: Appearance = .normal {
    didSet {
      updateStatusItemAppearance()
    }
  }

  var statusItem: NSStatusItem?
  private var cancellables = Set<AnyCancellable>()

  var handlePreferences: (() -> Void)?
  var handleAbout: (() -> Void)?
  var handleReloadConfig: (() -> Void)?
  var handleRevealConfig: (() -> Void)?
  var handleCheckForUpdates: (() -> Void)?

  // Karabiner-Elements ships an official signed CLI; we drive it, never rebuild.
  private let karabinerCLI =
    "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"

  // Live items rebuilt each time the menu opens (see menuNeedsUpdate).
  private var karabinerStatusItem: NSMenuItem?
  private var karabinerProfileItem: NSMenuItem?

  // Rectangle window actions, mirroring the rectangle:// binds in the Leader
  // Key config. `nil` title = a separator between visual groups.
  private let rectangleActions: [(title: String?, action: String)] = [
    ("Left Half", "left-half"), ("Right Half", "right-half"),
    ("Top Half", "top-half"), ("Bottom Half", "bottom-half"),
    (nil, ""),
    ("Maximize", "maximize"), ("Almost Maximize", "almost-maximize"),
    ("Center", "center"),
    (nil, ""),
    ("Top Left", "top-left"), ("Top Right", "top-right"),
    ("Bottom Left", "bottom-left"), ("Bottom Right", "bottom-right"),
    (nil, ""),
    ("First Third", "first-third"), ("Center Third", "center-third"),
    ("Last Third", "last-third"),
    (nil, ""),
    ("Next Display", "next-display"),
  ]

  func enable() {
    statusItem = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.squareLength)

    guard let item = statusItem else {
      print("No status item")
      return
    }

    if let menubarButton = item.button {
      menubarButton.image = NSImage(named: NSImage.Name("StatusItem"))
    }

    let menu = NSMenu()
    menu.delegate = self

    // Branded header
    let header = NSMenuItem(title: "MachineSpirit", action: nil, keyEquivalent: "")
    header.isEnabled = false
    header.image = NSImage(named: NSImage.Name("StatusItem"))
    menu.addItem(header)

    // ---- Leader Key ----
    menu.addItem(sectionHeader("Leader Key"))
    menu.addItem(actionItem("About", #selector(showAbout)))
    menu.addItem(actionItem("Settings…", #selector(showPreferences), key: ","))
    menu.addItem(actionItem("Reload config", #selector(reloadConfig)))
    menu.addItem(actionItem("Show config in Finder", #selector(revealConfigFile)))
    menu.addItem(actionItem("Check for Updates…", #selector(checkForUpdates)))

    // ---- Rectangle (via rectangle:// scheme) ----
    menu.addItem(sectionHeader("Rectangle — Windows"))
    for entry in rectangleActions {
      guard let title = entry.title else {
        menu.addItem(.separator())
        continue
      }
      let mi = actionItem(title, #selector(runRectangleAction(_:)))
      mi.representedObject = entry.action
      menu.addItem(mi)
    }
    menu.addItem(actionItem("Rectangle Settings…", #selector(openRectangleSettings)))

    // ---- Karabiner (status + profile via karabiner_cli) ----
    menu.addItem(sectionHeader("Karabiner — Keys"))
    let status = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
    status.isEnabled = false
    karabinerStatusItem = status
    menu.addItem(status)
    let profile = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
    karabinerProfileItem = profile
    menu.addItem(profile)
    menu.addItem(actionItem("Open Karabiner Settings…", #selector(openKarabinerSettings)))

    // ---- Quit (app-level: quits the whole fork, so it sits last per the
    // macOS convention; named for the app, not the Leader Key section) ----
    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: "Quit MachineSpirit",
        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
      ))

    item.menu = menu
    refreshKarabiner()
    updateStatusItemAppearance()

    Events.sink { event in
      switch event {
      case .willActivate:
        self.appearance = .active
        break
      case .willDeactivate:
        self.appearance = .normal
        break
      default:
        break
      }
    }.store(in: &cancellables)
  }

  func disable() {
    guard let item = statusItem else { return }

    cancellables.removeAll()
    NSStatusBar.system.removeStatusItem(item)
    statusItem = nil
  }

  // MARK: - Menu construction helpers

  private func sectionHeader(_ title: String) -> NSMenuItem {
    if #available(macOS 14.0, *) {
      return NSMenuItem.sectionHeader(title: title)
    }
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private func actionItem(_ title: String, _ selector: Selector, key: String = "")
    -> NSMenuItem
  {
    let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
    item.target = self
    return item
  }

  // MARK: - Leader Key actions

  @objc func showPreferences() { handlePreferences?() }
  @objc func showAbout() { handleAbout?() }
  @objc func reloadConfig() { handleReloadConfig?() }
  @objc func revealConfigFile() { handleRevealConfig?() }
  @objc func checkForUpdates() { handleCheckForUpdates?() }

  // MARK: - Rectangle actions

  @objc private func runRectangleAction(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String,
      let url = URL(string: "rectangle://execute-action?name=\(name)")
    else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func openRectangleSettings() {
    // Rectangle exposes no settings URL; activating the app brings its
    // Settings window forward (and re-reveals its icon if it was hidden).
    if let url = URL(string: "rectangle://") {
      NSWorkspace.shared.open(url)
    }
    activateApp(named: "Rectangle")
  }

  // MARK: - Karabiner status + profile

  @objc private func openKarabinerSettings() {
    activateApp(named: "Karabiner-Elements")
  }

  @objc private func selectKarabinerProfile(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String else { return }
    _ = runKarabiner(["--select-profile", name])
    refreshKarabiner()
  }

  /// Rebuild the live Karabiner status + profile submenu.
  private func refreshKarabiner() {
    let running = karabinerRunning()
    karabinerStatusItem?.title = running ? "● Active" : "○ Not running"

    guard let profileItem = karabinerProfileItem else { return }
    let current = runKarabiner(["--show-current-profile-name"]) ?? "—"
    profileItem.title = "Profile: \(current)"

    let names = (runKarabiner(["--list-profile-names"]) ?? "")
      .split(separator: "\n").map(String.init)
    if names.count > 1 {
      let sub = NSMenu()
      for name in names {
        let mi = NSMenuItem(
          title: name, action: #selector(selectKarabinerProfile(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = name
        mi.state = (name == current) ? .on : .off
        sub.addItem(mi)
      }
      profileItem.submenu = sub
      profileItem.isEnabled = true
    } else {
      profileItem.submenu = nil
      profileItem.isEnabled = false
    }
  }

  private func karabinerRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains {
      ($0.bundleIdentifier ?? "").hasPrefix("org.pqrs.Karabiner")
    } || processExists(matching: "Karabiner-Core-Service")
  }

  /// Run karabiner_cli with args; returns trimmed stdout, or nil on failure.
  private func runKarabiner(_ args: [String]) -> String? {
    guard FileManager.default.isExecutableFile(atPath: karabinerCLI) else { return nil }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: karabinerCLI)
    task.arguments = args
    let out = Pipe()
    task.standardOutput = out
    task.standardError = Pipe()
    do {
      try task.run()
      task.waitUntilExit()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      let s = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return (s?.isEmpty ?? true) ? nil : s
    } catch {
      return nil
    }
  }

  private func processExists(matching pattern: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", pattern]
    let out = Pipe()
    task.standardOutput = out
    task.standardError = Pipe()
    do {
      try task.run()
      task.waitUntilExit()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      return !(String(data: data, encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    } catch {
      return false
    }
  }

  // MARK: - Shared

  private func activateApp(named name: String) {
    NSWorkspace.shared.launchApplication(name)
    if let app = NSWorkspace.shared.runningApplications.first(where: {
      $0.localizedName == name
    }) {
      app.activate(options: [.activateIgnoringOtherApps])
    }
  }

  // MARK: - NSMenuDelegate

  func menuNeedsUpdate(_ menu: NSMenu) {
    refreshKarabiner()
  }

  // MARK: - Appearance

  private func updateStatusItemAppearance() {
    guard let button = statusItem?.button else { return }

    switch appearance {
    case .normal:
      button.image = NSImage(named: NSImage.Name("StatusItem"))
    case .active:
      // Summoned: the skull lights up machine-spirit green (design cache #2).
      // Force non-template so it renders in colour instead of being tinted to
      // the menu-bar foreground.
      let lit = NSImage(named: NSImage.Name("StatusItem-filled"))
      lit?.isTemplate = false
      button.image = lit
    }
  }
}

// MARK: - Sheol / terminal status item
//
// machine-spirit fork: a second menu-bar item beside the skull — the terminal +
// tmux ledger (design cache #15). Its title is three counts,
// "terminals · tmux-live · tmux-detached": all live iTerm sessions, then tmux
// sessions with a client attached (living), then detached-but-running ones
// (wandering spirits). The menu lists the tmux sections (revive / detach / ✕
// banish) and, at the bottom, every live terminal (click to focus). tmux reads
// go through ~/bin/sheol-core and terminal reads through ~/bin/terminals-core —
// the SAME doors the TUI and MachineSpirit.app use, so the surfaces can never
// disagree. tmux is polled every 5s; terminals (an Apple Event to iTerm, plus a
// ps snapshot — far pricier) every 45s. The menu force-refreshes on open, so
// the background terminal poll only keeps the glanceable title count from going
// stale — which needs nowhere near 8s freshness, and 8s cost ~0.85s/tick forever.
final class SheolStatusItem: NSObject, NSMenuDelegate {
  private var statusItem: NSStatusItem?
  private var pollTimer: Timer?

  private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
  private var corePath: String { home.appendingPathComponent("bin/sheol-core").path }
  private var openerPath: String {
    home.appendingPathComponent("bin/tmux-sheol-open.sh").path
  }

  /// One tmux session as sheol-core reports it (mirrors the app's Spirit).
  private struct Spirit: Decodable {
    let name: String
    let attached: Int
    let created: Int
    let activity: Int
    let command: String
    var isWandering: Bool { attached == 0 }
    var quietFor: String {
      let s = max(0, Int(Date().timeIntervalSince1970) - activity)
      let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
      if d > 0 { return "\(d)d\(h)h" }
      if h > 0 { return "\(h)h\(m)m" }
      return "\(m)m"
    }
  }

  private var spirits: [Spirit] = []

  // Live terminals (iTerm sessions) via ~/bin/terminals-core — the first count
  // in the title and the "Terminals" menu section. Terminal reads go through
  // that helper the way tmux reads go through sheol-core.
  private var termPath: String { home.appendingPathComponent("bin/terminals-core").path }
  private struct Terminal: Decodable {
    let id: String
    let tty: String
    let name: String
    let isTmux: Bool
  }
  private var terminals: [Terminal] = []
  private var termPollTimer: Timer?

  // Retains the ☠ BANISH ALL type-to-confirm panel while it's on screen.
  private var banishPanel: BanishAllPanel?

  // Section-header items captured on menu build, so a banish can hide an
  // emptied section in place (the ledger stays open across successive kills).
  private weak var livingHeaderItem: NSMenuItem?
  private weak var wanderingHeaderItem: NSMenuItem?

  func enable() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.image = NSImage(
        systemSymbolName: "terminal", accessibilityDescription: "terminals + tmux")
      button.image?.isTemplate = true
      button.imagePosition = .imageLeading
      button.title = " 0 · 0 · 0"  // terminals · tmux-live · tmux-detached
    }
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    statusItem = item
    refresh(background: true)  // tmux — cheap
    refreshTerminals(background: true)  // terminals — osascript, off-main

    // Keep the counts live even without opening the menu. tmux is cheap (5s);
    // the terminal enumeration is an Apple Event to iTerm + a ps snapshot, so
    // poll it much slower (45s) — the menu force-refreshes on open anyway, so
    // this background tick only feeds the always-visible title count.
    let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) {
      [weak self] _ in self?.refresh(background: true)
    }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer

    let tTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) {
      [weak self] _ in self?.refreshTerminals(background: true)
    }
    RunLoop.main.add(tTimer, forMode: .common)
    termPollTimer = tTimer
  }

  func disable() {
    pollTimer?.invalidate()
    pollTimer = nil
    termPollTimer?.invalidate()
    termPollTimer = nil
    if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
    statusItem = nil
  }

  // MARK: - Data (the process runs off-main; UI mutates on main)

  private func refresh(background: Bool) {
    if background {
      DispatchQueue.global(qos: .utility).async { [weak self] in
        guard let self else { return }
        let fresh = Self.list(core: self.corePath)
        DispatchQueue.main.async { self.apply(fresh) }
      }
    } else {
      apply(Self.list(core: corePath))
    }
  }

  private func apply(_ fresh: [Spirit]) {
    spirits = fresh
    updateTitle()
  }

  private func refreshTerminals(background: Bool) {
    if background {
      DispatchQueue.global(qos: .utility).async { [weak self] in
        guard let self else { return }
        let terms = Self.listTerminals(core: self.termPath)
        DispatchQueue.main.async {
          self.terminals = terms
          self.updateTitle()
          // NB: intentionally does NOT repaint an open menu — mutating the menu
          // under the cursor could shift a row mid-click (a data-loss hazard next
          // to banish). The open list is the last poll; it refreshes on next open.
        }
      }
    } else {
      terminals = Self.listTerminals(core: termPath)
      updateTitle()
    }
  }

  /// The title is three counts: (non-tmux) terminals · live tmux · detached
  /// tmux. tmux terminals are counted only as tmux — they live in their own
  /// sections — so the three numbers never double-count the same session.
  private func updateTitle() {
    let liveTmux = spirits.filter { !$0.isWandering }.count
    let deadTmux = spirits.filter { $0.isWandering }.count
    let terms = terminals.filter { !$0.isTmux }.count
    statusItem?.button?.title = " \(terms) · \(liveTmux) · \(deadTmux)"
    statusItem?.button?.toolTip =
      "\(terms) terminals · \(liveTmux) tmux live · \(deadTmux) tmux detached (running, hidden)"
  }

  private static func list(core: String) -> [Spirit] {
    guard FileManager.default.isExecutableFile(atPath: core) else { return [] }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: core)
    task.arguments = ["list", "--json"]
    let out = Pipe()
    task.standardOutput = out
    task.standardError = Pipe()
    do {
      try task.run()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      task.waitUntilExit()
      return (try? JSONDecoder().decode([Spirit].self, from: data)) ?? []
    } catch {
      return []
    }
  }

  private static func listTerminals(core: String) -> [Terminal] {
    guard FileManager.default.isExecutableFile(atPath: core) else { return [] }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: core)
    task.arguments = ["list", "--json"]
    let out = Pipe()
    task.standardOutput = out
    task.standardError = Pipe()
    do {
      try task.run()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      task.waitUntilExit()
      return (try? JSONDecoder().decode([Terminal].self, from: data)) ?? []
    } catch {
      return []
    }
  }

  /// Fire-and-forget a terminals-core verb (focus) off the main thread.
  private func runTerm(_ args: [String]) {
    let core = termPath
    guard FileManager.default.isExecutableFile(atPath: core) else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      let task = Process()
      task.executableURL = URL(fileURLWithPath: core)
      task.arguments = args
      task.standardOutput = FileHandle.nullDevice
      task.standardError = FileHandle.nullDevice
      try? task.run()
    }
  }

  /// Fire-and-forget a sheol-core verb (revive/detach) off the main thread.
  private func runCore(_ args: [String]) {
    let core = corePath
    guard FileManager.default.isExecutableFile(atPath: core) else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      let task = Process()
      task.executableURL = URL(fileURLWithPath: core)
      task.arguments = args
      task.standardOutput = FileHandle.nullDevice
      task.standardError = FileHandle.nullDevice
      try? task.run()
    }
  }

  // MARK: - Menu (rebuilt fresh on every open)

  func menuNeedsUpdate(_ menu: NSMenu) {
    rebuildMenu(menu)
  }

  func menuWillOpen(_ menu: NSMenu) {
    // Terminal enumeration is a ~0.7s Apple Event, too slow to block the menu on;
    // this open shows the last poll, so freshen the list for the NEXT open.
    refreshTerminals(background: true)
  }

  /// Build the menu from current cached state. Must NOT trigger a terminal
  /// refresh (callers do), so the async refresh completion can call this to
  /// repaint an open menu without recursing.
  private func rebuildMenu(_ menu: NSMenu) {
    apply(Self.list(core: corePath))  // accurate the instant it appears
    menu.removeAllItems()

    let living = spirits.filter { !$0.isWandering }
    let wandering = spirits.filter { $0.isWandering }
    menu.addItem(
      sectionHeader("Sheol — \(living.count) living · \(wandering.count) wandering"))

    if spirits.isEmpty {
      let none = NSMenuItem(title: "No tmux sessions", action: nil, keyEquivalent: "")
      none.isEnabled = false
      menu.addItem(none)
    } else {
      // Size every row to the widest label so full names never clip; trailing
      // controls stay right-aligned across all rows.
      let labelW = min(
        360, ceil(spirits.map { Self.rowLabel(for: $0).size().width }.max() ?? 120))
      let rowW = labelW + 92  // label + gaps + detach slot + kill/ward slot + pad
      livingHeaderItem = nil
      wanderingHeaderItem = nil
      if !living.isEmpty {
        let h = sectionHeader("Living (attached)")
        livingHeaderItem = h
        menu.addItem(h)
        for s in living { menu.addItem(rowItem(s, labelW: labelW, rowW: rowW)) }
      }
      if !wandering.isEmpty {
        let h = sectionHeader("Sheol (wandering)")
        wanderingHeaderItem = h
        menu.addItem(h)
        for s in wandering { menu.addItem(rowItem(s, labelW: labelW, rowW: rowW)) }
      }
    }

    // ── session survival: save · restore · banish-all ─────────────────────────
    menu.addItem(.separator())
    if let age = Self.lastSaveAge(core: corePath) {
      let hdr = NSMenuItem(title: "Snapshot — \(age)", action: nil, keyEquivalent: "")
      hdr.isEnabled = false
      menu.addItem(hdr)
    }
    let save = NSMenuItem(
      title: "💾  Save layout now", action: #selector(saveLayout), keyEquivalent: "")
    save.target = self
    menu.addItem(save)
    let restore = NSMenuItem(
      title: "♻  Restore last snapshot", action: #selector(restoreLayout), keyEquivalent: "")
    restore.target = self
    menu.addItem(restore)
    if !spirits.isEmpty {
      // The nuke. Opens a type-to-confirm panel (you type BANISH, the letters
      // light up) rather than firing on click — typing inside an open menu fights
      // the menu's own type-select, and this is irreversible-adjacent, so it wants
      // a deliberate, visible gate. kill-all saves first, so it's undoable with ♻.
      let banish = NSMenuItem(
        title: "☠  BANISH ALL…", action: #selector(confirmBanishAll), keyEquivalent: "")
      banish.target = self
      menu.addItem(banish)
    }

    menu.addItem(.separator())
    let open = NSMenuItem(
      title: "Open sheol ledger…", action: #selector(openLedger), keyEquivalent: "")
    open.target = self
    menu.addItem(open)

    // ---- Terminals: every live NON-tmux terminal (tmux keeps its own lists
    // above, so a session is never listed twice). Name click = focus; the red ✕
    // closes it via the same triple-tap ◆◆◇ ward as the sheol banish. Only iTerm
    // sessions get the ✕ (an "app:" row isn't a single session we can target). ----
    let plainTerms = terminals.filter { !$0.isTmux }
    menu.addItem(.separator())
    menu.addItem(sectionHeader("Terminals — \(plainTerms.count) live"))
    if plainTerms.isEmpty {
      let none = NSMenuItem(title: "No terminals", action: nil, keyEquivalent: "")
      none.isEnabled = false
      menu.addItem(none)
    } else {
      let font = NSFont.menuFont(ofSize: 0)
      let labelW = min(
        360,
        ceil(
          plainTerms.map {
            NSAttributedString(
              string: "❯  " + $0.name.replacingOccurrences(of: "\n", with: " "),
              attributes: [.font: font]).size().width
          }.max() ?? 160))
      let rowW = labelW + 60  // label + ✕ slot + pad
      for term in plainTerms {
        var label = term.name.replacingOccurrences(of: "\n", with: " ")
        if label.count > 52 { label = String(label.prefix(51)) + "…" }
        let item = NSMenuItem()
        item.view = TerminalRow(
          id: term.id, title: "❯  " + label, tty: term.tty,
          canKill: !term.id.hasPrefix("app:"),
          labelW: labelW, rowW: rowW, owner: self)
        menu.addItem(item)
      }
    }
    // The terminal rows above are the last poll's; menuWillOpen kicks a fresh
    // read so the NEXT open is current (mutating the open menu could shift a row
    // under the cursor next to a ✕ — a data-loss hazard we deliberately avoid).
  }

  @objc fileprivate func focusTerminalRow(_ sender: SheolRowButton) {
    statusItem?.menu?.cancelTracking()
    runTerm(["focus", sender.sessionName])
  }

  /// Close a terminal — the same triple-tap ward as killRow, calling
  /// terminals-core kill. The ledger stays open so you can close several; the
  /// retired row hides in place (a reopen rebuilds fresh regardless).
  @objc fileprivate func killTerminalRow(_ sender: SheolRowButton) {
    sender.wardTimer?.invalidate()
    sender.wardTaps += 1
    if sender.wardTaps >= 3 {
      let id = sender.sessionName
      sender.resetWard()
      runTerm(["kill", id])
      retireTerminalRow(sender)
      return
    }
    sender.showWard(remaining: 3 - sender.wardTaps)
    let timer = Timer(timeInterval: 1.4, repeats: false) { [weak sender] _ in
      sender?.resetWard()
    }
    RunLoop.main.add(timer, forMode: .common)
    sender.wardTimer = timer
  }

  /// Hide a just-closed terminal row in place (no section-header bookkeeping —
  /// the Terminals header count just reads stale until the next open).
  private func retireTerminalRow(_ button: SheolRowButton) {
    let t = Timer(timeInterval: 0.01, repeats: false) { [weak button] _ in
      button?.enclosingMenuItem?.isHidden = true
    }
    RunLoop.main.add(t, forMode: .common)
  }

  /// The two-tone row label: session name in the primary color, then a dimmed
  /// "· command · quiet" trailer.
  private static func rowLabel(for spirit: Spirit) -> NSAttributedString {
    let dot = spirit.isWandering ? "○ " : "● "
    let s = NSMutableAttributedString(
      string: dot + spirit.name,
      attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.menuFont(ofSize: 0)])
    s.append(
      NSAttributedString(
        string: "   ·  \(spirit.command) · \(spirit.quietFor)",
        attributes: [
          .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0),
        ]))
    return s
  }

  /// A session row is a custom view sized to `rowW`: the name (click = revive /
  /// attach in a new iTerm window) plus trailing controls — a moon that sends a
  /// LIVING session to sheol (detach), and a red ✕ that banishes it (triple-tap
  /// arms the decaying ◆◆◇ ward, no dialog — the menu-bar echo of the TUI).
  private func rowItem(_ spirit: Spirit, labelW: CGFloat, rowW: CGFloat) -> NSMenuItem {
    let item = NSMenuItem()
    let dot = spirit.isWandering ? "○ " : "● "
    item.view = SheolRow(
      name: spirit.name, title: dot + spirit.name,
      subtitle: "   ·  \(spirit.command) · \(spirit.quietFor)",
      labelW: labelW, rowW: rowW, isWandering: spirit.isWandering, owner: self)
    return item
  }

  private func sectionHeader(_ title: String) -> NSMenuItem {
    if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  // Row actions. revive + detach dismiss the ledger, then act (both reversible).
  // kill (banish) is guarded by a triple-tap ward and deliberately keeps the
  // ledger open so you can banish several sessions in a row.
  @objc fileprivate func reviveRow(_ sender: SheolRowButton) {
    statusItem?.menu?.cancelTracking()
    runCore(["revive", sender.sessionName])
  }

  @objc fileprivate func detachRow(_ sender: SheolRowButton) {
    statusItem?.menu?.cancelTracking()
    runCore(["detach", sender.sessionName])  // living -> sheol
  }

  /// Banish is triple-tap, not a dialog: each ✕ tap decays the ◆◆◇ ward and
  /// re-arms a short reset timer; the third tap within the window kills. The
  /// ledger stays open throughout — including after the kill — so you can
  /// banish several sessions in a row; the retired row just hides itself.
  /// Mirrors the TUI's d·d·d ward — irreversible, so it wants deliberate taps.
  @objc fileprivate func killRow(_ sender: SheolRowButton) {
    sender.wardTimer?.invalidate()
    sender.wardTaps += 1
    if sender.wardTaps >= 3 {
      let name = sender.sessionName
      sender.resetWard()
      runCore(["kill", name])
      // Don't dismiss the ledger — banishing a couple in a row is the point.
      // Retire this row (and any header it empties) in place; a reopen rebuilds
      // fresh from tmux regardless.
      retireRow(sender)
      return
    }
    sender.showWard(remaining: 3 - sender.wardTaps)
    // The reset timer must fire during menu tracking → .common run-loop mode.
    let timer = Timer(timeInterval: 1.4, repeats: false) { [weak sender] _ in
      sender?.resetWard()
    }
    RunLoop.main.add(timer, forMode: .common)
    sender.wardTimer = timer
  }

  /// Hide a just-banished row and collapse its section header if that was the
  /// section's last row, leaving the ledger open for the next banish. Deferred
  /// onto a .common-mode timer — the one dispatch this menu is proven to service
  /// while open — so we don't restructure the menu inside its own event handler.
  private func retireRow(_ button: SheolRowButton) {
    let t = Timer(timeInterval: 0.01, repeats: false) { [weak self, weak button] _ in
      guard let self, let button, let menu = self.statusItem?.menu else { return }
      button.enclosingMenuItem?.isHidden = true
      func remaining(wandering: Bool) -> Int {
        menu.items.filter {
          guard let row = $0.view as? SheolRow, !$0.isHidden else { return false }
          return row.isWandering == wandering
        }.count
      }
      self.livingHeaderItem?.isHidden = remaining(wandering: false) == 0
      self.wanderingHeaderItem?.isHidden = remaining(wandering: true) == 0
    }
    RunLoop.main.add(t, forMode: .common)
  }

  @objc private func openLedger() {
    guard FileManager.default.isExecutableFile(atPath: openerPath) else { return }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: openerPath)
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
  }

  // MARK: - Session survival (save / restore / banish-all)

  @objc private func saveLayout() { runCore(["save"]) }
  @objc private func restoreLayout() { runCore(["restore"]) }

  /// ☠ BANISH ALL — show the type-to-confirm panel; fire kill-all only when the
  /// user types the whole word. kill-all snapshots first, so ♻ Restore undoes it.
  @objc private func confirmBanishAll() {
    let count = spirits.count
    let panel = BanishAllPanel()
    banishPanel = panel
    panel.show(count: count) { [weak self] in self?.runCore(["kill-all"]) }
  }

  /// Human "saved Nm ago" for the snapshot header, or nil if sheol-core is
  /// missing. Cheap (a stat via `last-save`); runs inline like `list` does.
  private static func lastSaveAge(core: String) -> String? {
    guard FileManager.default.isExecutableFile(atPath: core) else { return nil }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: core)
    task.arguments = ["last-save"]
    let out = Pipe()
    task.standardOutput = out
    task.standardError = Pipe()
    do {
      try task.run()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      task.waitUntilExit()
      let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      let epoch = Int(text) ?? 0
      if epoch == 0 { return "never saved" }
      let secs = max(0, Int(Date().timeIntervalSince1970) - epoch)
      let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
      if d > 0 { return "saved \(d)d\(h)h ago" }
      if h > 0 { return "saved \(h)h\(m)m ago" }
      if m > 0 { return "saved \(m)m ago" }
      return "saved just now"
    } catch {
      return nil
    }
  }
}

/// The ☠ BANISH ALL confirmation: a small floating panel where you type the word
/// BANISH and watch each letter light up. Reliable window key-handling (unlike
/// typing inside a tracking NSMenu), and a deliberately visible gate for a
/// destructive action. The confirm button enables only on the exact word.
final class BanishAllPanel: NSObject, NSTextFieldDelegate {
  private var panel: NSPanel?
  private var cells: [NSTextField] = []
  private var field: NSTextField?
  private var confirmButton: NSButton?
  private var onConfirm: (() -> Void)?
  private let word = "BANISH"

  func show(count: Int, onConfirm: @escaping () -> Void) {
    self.onConfirm = onConfirm
    let w: CGFloat = 400, h: CGFloat = 220
    let p = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: w, height: h),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    p.title = "Banish all spirits"
    p.isFloatingPanel = true
    p.level = .modalPanel
    p.center()
    guard let v = p.contentView else { return }

    let head = NSTextField(labelWithString: "☠  BANISH ALL")
    head.font = .boldSystemFont(ofSize: 18)
    head.textColor = .systemRed
    head.frame = NSRect(x: 24, y: h - 54, width: w - 48, height: 26)
    v.addSubview(head)

    let sub = NSTextField(
      wrappingLabelWithString:
        "\(count) tmux session\(count == 1 ? "" : "s") will be killed. A snapshot is "
        + "saved first — bring them back with ♻ Restore.")
    sub.font = .systemFont(ofSize: 11)
    sub.textColor = .secondaryLabelColor
    sub.frame = NSRect(x: 24, y: h - 100, width: w - 48, height: 38)
    v.addSubview(sub)

    // letter cells — dim, then red-bold as each matching letter is typed
    let cw: CGFloat = 42, gap: CGFloat = 8
    let totalW = CGFloat(word.count) * cw + CGFloat(word.count - 1) * gap
    var x = (w - totalW) / 2
    for ch in word {
      let c = NSTextField(labelWithString: String(ch))
      c.alignment = .center
      c.font = .monospacedSystemFont(ofSize: 20, weight: .bold)
      c.textColor = .tertiaryLabelColor
      c.frame = NSRect(x: x, y: 104, width: cw, height: 34)
      c.wantsLayer = true
      c.layer?.borderWidth = 1
      c.layer?.borderColor = NSColor.separatorColor.cgColor
      c.layer?.cornerRadius = 6
      v.addSubview(c)
      cells.append(c)
      x += cw + gap
    }

    let f = NSTextField(frame: NSRect(x: 24, y: 60, width: w - 48, height: 24))
    f.placeholderString = "type BANISH to confirm"
    f.alignment = .center
    f.delegate = self
    v.addSubview(f)
    field = f

    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
    cancel.frame = NSRect(x: w - 192, y: 16, width: 84, height: 30)
    cancel.bezelStyle = .rounded
    cancel.keyEquivalent = "\u{1b}"  // Esc
    v.addSubview(cancel)

    let ok = NSButton(title: "Banish all", target: self, action: #selector(confirm))
    ok.frame = NSRect(x: w - 100, y: 16, width: 88, height: 30)
    ok.bezelStyle = .rounded
    ok.keyEquivalent = "\r"
    ok.isEnabled = false
    v.addSubview(ok)
    confirmButton = ok

    panel = p
    NSApp.activate(ignoringOtherApps: true)
    p.makeKeyAndOrderFront(nil)
    p.makeFirstResponder(f)
  }

  func controlTextDidChange(_ obj: Notification) {
    let typed = Array((field?.stringValue ?? "").uppercased())
    let target = Array(word)
    for (i, c) in cells.enumerated() {
      let lit = i < typed.count && typed[i] == target[i]
      c.textColor = lit ? .systemRed : .tertiaryLabelColor
      c.layer?.borderColor = (lit ? NSColor.systemRed : NSColor.separatorColor).cgColor
    }
    confirmButton?.isEnabled = (typed == target)
  }

  @objc private func confirm() {
    guard (field?.stringValue ?? "").uppercased() == word else { return }
    let cb = onConfirm
    close()
    cb?()
  }

  @objc private func cancel() { close() }

  private func close() {
    panel?.close()
    panel = nil
    cells = []
    field = nil
    confirmButton = nil
  }
}

/// A menu-row button that remembers its session and, for the kill ✕, holds the
/// decaying-ward state (taps so far + the reset timer). `showWard`/`resetWard`
/// swap the ✕ image for the ◆◆◇ ward glyphs and back.
private final class SheolRowButton: NSButton {
  var sessionName = ""
  var wardTaps = 0
  var wardTimer: Timer?
  var wardVerb = "Banish"  // "Close" for terminal rows — same ward, different word
  private var restImage: NSImage?

  /// Show `remaining` filled diamonds out of 3 (◆◆◇ → ◆◇◇) in place of the ✕.
  func showWard(remaining: Int) {
    if restImage == nil { restImage = image }
    image = nil
    imagePosition = .noImage
    let glyphs = String(repeating: "◆", count: max(0, remaining))
      + String(repeating: "◇", count: max(0, 3 - remaining))
    attributedTitle = NSAttributedString(
      string: glyphs,
      attributes: [
        .foregroundColor: NSColor.systemRed,
        .font: NSFont.systemFont(ofSize: 10, weight: .bold),
      ])
    toolTip = "Tap \(remaining) more to \(wardVerb.lowercased())"
  }

  /// Ward decayed or completed — restore the ✕.
  func resetWard() {
    wardTimer?.invalidate()
    wardTimer = nil
    wardTaps = 0
    attributedTitle = NSAttributedString(string: "")
    imagePosition = .imageOnly
    image = restImage
    toolTip = "\(wardVerb) — tap 3× (◆◆◇ ward)"
  }
}

/// One row in the menu-bar Terminals section: a name button (click = focus that
/// terminal) and, for an iTerm session, a red ✕ that closes it via the same
/// triple-tap ◆◆◇ ward as the sheol banish. "app:" rows omit the ✕ (no single
/// session to target). Mirrors SheolRow's hover highlight so the sections match.
private final class TerminalRow: NSView {
  private let title: String
  private let nameButton: SheolRowButton
  private let killButton: SheolRowButton?
  private var hovered = false
  private var trackingArea: NSTrackingArea?

  init(
    id: String, title: String, tty: String, canKill: Bool,
    labelW: CGFloat, rowW: CGFloat, owner: SheolStatusItem
  ) {
    self.title = title
    let h: CGFloat = 22

    let focus = SheolRowButton(frame: NSRect(x: 6, y: 0, width: labelW, height: h))
    focus.sessionName = id
    focus.isBordered = false
    focus.imagePosition = .noImage
    focus.alignment = .left
    (focus.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    focus.attributedTitle = Self.label(title: title, hovered: false)
    focus.target = owner
    focus.action = #selector(SheolStatusItem.focusTerminalRow(_:))
    focus.toolTip = "\(tty) — click to focus"
    self.nameButton = focus

    if canKill {
      let kill = SheolRowButton()
      kill.sessionName = id
      kill.wardVerb = "Close"
      kill.isBordered = false
      kill.bezelStyle = .regularSquare
      kill.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "close")
      kill.imagePosition = .imageOnly
      kill.contentTintColor = .systemRed
      kill.toolTip = "Close — tap 3× (◆◆◇ ward)"
      kill.frame = NSRect(x: rowW - 46, y: 1, width: 40, height: 20)
      kill.target = owner
      kill.action = #selector(SheolStatusItem.killTerminalRow(_:))
      self.killButton = kill
    } else {
      self.killButton = nil
    }

    super.init(frame: NSRect(x: 0, y: 0, width: rowW, height: h))
    addSubview(nameButton)
    if let killButton { addSubview(killButton) }
  }

  required init?(coder: NSCoder) { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let ta = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(ta)
    trackingArea = ta
  }

  override func mouseEntered(with event: NSEvent) { setHovered(true) }
  override func mouseExited(with event: NSEvent) { setHovered(false) }

  private func setHovered(_ h: Bool) {
    guard hovered != h else { return }
    hovered = h
    nameButton.attributedTitle = Self.label(title: title, hovered: h)
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard hovered else { return }
    NSColor.selectedContentBackgroundColor.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
  }

  static func label(title: String, hovered: Bool) -> NSAttributedString {
    NSAttributedString(
      string: title,
      attributes: [
        .foregroundColor: hovered ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
        .font: NSFont.menuFont(ofSize: 0),
      ])
  }
}

/// The custom view for one sheol session row: a borderless name button (click =
/// revive) plus trailing icon buttons — a moon that sends a living session to
/// sheol (detach) and a red ✕ that banishes it via triple-tap. The view is
/// sized to `rowW` so names never clip and the controls line up across rows.
private final class SheolRow: NSView {
  let isWandering: Bool
  private let title: String
  private let subtitle: String
  private let nameButton: SheolRowButton
  private let detachButton: SheolRowButton?
  private let killButton: SheolRowButton
  private var hovered = false
  private var trackingArea: NSTrackingArea?

  init(
    name: String, title: String, subtitle: String, labelW: CGFloat, rowW: CGFloat,
    isWandering: Bool, owner: SheolStatusItem
  ) {
    self.isWandering = isWandering
    self.title = title
    self.subtitle = subtitle
    let h: CGFloat = 22

    // Name — borderless button sized to the measured label (no clipping).
    let revive = SheolRowButton(frame: NSRect(x: 6, y: 0, width: labelW, height: h))
    revive.sessionName = name
    revive.isBordered = false
    revive.imagePosition = .noImage
    revive.alignment = .left
    (revive.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    revive.attributedTitle = Self.label(title: title, subtitle: subtitle, hovered: false)
    revive.target = owner
    revive.action = #selector(SheolStatusItem.reviveRow(_:))
    revive.toolTip =
      isWandering
      ? "Revive — reattach in a new iTerm window"
      : "Open another window attached to this session"
    self.nameButton = revive

    // Kill (banish) — the ✕, in red; wider than a plain icon so the ◆◆◇ ward
    // fits when armed. Triple-tap handled in SheolStatusItem.killRow.
    let kill = Self.icon("xmark.circle.fill", name: name, tip: "Banish — tap 3× (◆◆◇ ward)")
    kill.contentTintColor = .systemRed
    kill.frame = NSRect(x: rowW - 46, y: 1, width: 40, height: 20)
    kill.target = owner
    kill.action = #selector(SheolStatusItem.killRow(_:))
    self.killButton = kill

    // Detach (the sleepy moon) — only on a living, attached session.
    if !isWandering {
      let detach = Self.icon("moon.zzz", name: name, tip: "Send to sheol (detach)")
      detach.frame = NSRect(x: rowW - 74, y: 1, width: 22, height: 20)
      detach.target = owner
      detach.action = #selector(SheolStatusItem.detachRow(_:))
      self.detachButton = detach
    } else {
      self.detachButton = nil
    }

    super.init(frame: NSRect(x: 0, y: 0, width: rowW, height: h))
    addSubview(nameButton)
    addSubview(killButton)
    if let detachButton { addSubview(detachButton) }
  }

  required init?(coder: NSCoder) { nil }

  // MARK: hover highlight — custom menu views don't get it for free, so track
  // the pointer and paint the standard selection behind the controls, matching
  // the plain Terminals rows.

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let ta = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(ta)
    trackingArea = ta
  }

  override func mouseEntered(with event: NSEvent) { setHovered(true) }
  override func mouseExited(with event: NSEvent) { setHovered(false) }

  private func setHovered(_ h: Bool) {
    guard hovered != h else { return }
    hovered = h
    nameButton.attributedTitle = Self.label(title: title, subtitle: subtitle, hovered: h)
    // The moon needs to read on the accent fill; the ✕/ward stay red (still
    // legible, and red is meaningful for a destructive control).
    detachButton?.contentTintColor = h ? .selectedMenuItemTextColor : nil
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard hovered else { return }
    NSColor.selectedContentBackgroundColor.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
  }

  static func label(title: String, subtitle: String, hovered: Bool) -> NSAttributedString {
    let nameColor: NSColor = hovered ? .selectedMenuItemTextColor : .labelColor
    let subColor: NSColor = hovered ? .selectedMenuItemTextColor : .secondaryLabelColor
    let s = NSMutableAttributedString(
      string: title,
      attributes: [.foregroundColor: nameColor, .font: NSFont.menuFont(ofSize: 0)])
    s.append(
      NSAttributedString(
        string: subtitle,
        attributes: [
          .foregroundColor: hovered ? subColor.withAlphaComponent(0.8) : subColor,
          .font: NSFont.menuFont(ofSize: 0),
        ]))
    return s
  }

  private static func icon(_ symbol: String, name: String, tip: String) -> SheolRowButton {
    let b = SheolRowButton()
    b.sessionName = name
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
    b.imagePosition = .imageOnly
    b.toolTip = tip
    return b
  }
}
