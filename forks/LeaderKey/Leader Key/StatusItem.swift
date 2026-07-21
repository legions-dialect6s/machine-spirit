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

// MARK: - Sheol tmux status item
//
// machine-spirit fork: a second menu-bar item beside the skull — the sheol
// "nag" (design cache #15). Its title is two counts, "active, invisible":
// sessions with a client attached (living), then detached-but-running sessions
// (wandering spirits). Always shown — "0, 0" when nothing runs. Every tmux
// touch goes through ~/bin/sheol-core, the SAME door the TUI
// (bin/tmux-sheol.sh) and MachineSpirit.app use, so the three surfaces can
// never disagree. Reads are cheap; the item polls on a timer and rebuilds its
// menu (with a fresh read) each time it opens.
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

  func enable() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.image = NSImage(
        systemSymbolName: "terminal", accessibilityDescription: "tmux sessions")
      button.image?.isTemplate = true
      button.imagePosition = .imageLeading
      button.title = " 0, 0"  // placeholder until the first poll returns
    }
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    statusItem = item
    refresh(background: true)  // non-blocking at launch

    // Keep the counts live even without opening the menu. 5s is plenty for a
    // menu-bar nag and stays far below any redraw-pileup concern.
    let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) {
      [weak self] _ in self?.refresh(background: true)
    }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
  }

  func disable() {
    pollTimer?.invalidate()
    pollTimer = nil
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
    let active = fresh.filter { !$0.isWandering }.count
    let invisible = fresh.filter { $0.isWandering }.count
    statusItem?.button?.title = " \(active), \(invisible)"
    statusItem?.button?.toolTip =
      "tmux — \(active) active, \(invisible) running but hidden (detached)"
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
      if !living.isEmpty {
        menu.addItem(sectionHeader("Living (attached)"))
        for spirit in living { menu.addItem(sessionItem(spirit, glyph: "●")) }
      }
      if !wandering.isEmpty {
        menu.addItem(sectionHeader("Sheol (wandering)"))
        for spirit in wandering { menu.addItem(sessionItem(spirit, glyph: "○")) }
      }
    }

    menu.addItem(.separator())
    let open = NSMenuItem(
      title: "Open sheol ledger…", action: #selector(openLedger), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
  }

  /// A session row: click reattaches it in a new iTerm window (revive). For a
  /// living session that's a second view; for a wandering one it's a revival.
  /// Irreversible verbs (banish) stay in the full ledger, behind its ◆◆◇ ward.
  private func sessionItem(_ spirit: Spirit, glyph: String) -> NSMenuItem {
    let title = "\(glyph)  \(spirit.name)   ·   \(spirit.command)  ·  \(spirit.quietFor)"
    let item = NSMenuItem(
      title: title, action: #selector(reviveSession(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = spirit.name
    item.toolTip =
      spirit.isWandering
      ? "Revive — reattach this spirit in a new iTerm window"
      : "Open another iTerm window attached to this session"
    return item
  }

  private func sectionHeader(_ title: String) -> NSMenuItem {
    if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  @objc private func reviveSession(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String else { return }
    runCore(["revive", name])
  }

  @objc private func openLedger() {
    guard FileManager.default.isExecutableFile(atPath: openerPath) else { return }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: openerPath)
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
  }
}
