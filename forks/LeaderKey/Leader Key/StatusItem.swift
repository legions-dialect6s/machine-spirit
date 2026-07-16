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
