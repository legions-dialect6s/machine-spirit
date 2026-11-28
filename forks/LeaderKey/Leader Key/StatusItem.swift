import Cocoa
import Combine

class StatusItem: NSObject, NSMenuDelegate {
  private var mainMenu: NSMenu?
  var statusItem: NSStatusItem?
  private var cancellables = Set<AnyCancellable>()
  let system = SystemMenuSection()
  let sheol = SheolMenuSection()
  let stats = SystemStats()
  let nowPlaying = NowPlayingMenuSection()
  private var pressure = MemoryPressure.Reading()
  private var timer: Timer?
  private var lastRender: CompactBarState?
  private var skullView: StatusSkullView?
  private let t3 = T3TaskMenu()
  private var nextSheolSample: TimeInterval = 0
  private var statsRows: [String: NSMenuItem] = [:]
  private var statsSummaryItem: NSMenuItem?
  private var statsMenu: NSMenu?
  private var menuIsOpen = false
  private var appearanceObservation: NSKeyValueObservation?
  var heartbeat: (() -> Void)?
  static let barSegments = [
    "Skull", "T3", "CPU", "GPU", "Memory", "Temperature", "Disks", "Awake",
  ]
  private var segments: [String] { Self.barSegments }
  private var enabledSegments = Set<String>()
  private var backingScale: CGFloat = 2

  var handlePreferences: (() -> Void)?
  var handleAbout: (() -> Void)?
  var handleReloadConfig: (() -> Void)?
  var handleRevealConfig: (() -> Void)?

  // Karabiner-Elements ships an official signed CLI; we drive it, never rebuild.
  // Karabiner 17 moved the CLI into the app bundle; keep the pre-17 path as fallback.
  private let karabinerCLI: String =
    [
      "/Applications/Karabiner-Elements.app/Contents/Helpers/karabiner_cli",
      "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }
    ?? "/Applications/Karabiner-Elements.app/Contents/Helpers/karabiner_cli"

  // Live items rebuilt each time the menu opens.
  private var karabinerStatusItem: NSMenuItem?
  private var karabinerProfileItem: NSMenuItem?
  private weak var karabinerMenu: NSMenu?

  // Rectangle window actions, mirroring the rectangle:// binds in the Leader
  // Key config.
  private let rectangleActions: [(title: String, action: String)] = [
    ("Left Half", "left-half"), ("Right Half", "right-half"),
    ("Top Half", "top-half"), ("Bottom Half", "bottom-half"),
    ("Maximize", "maximize"), ("Almost Maximize", "almost-maximize"),
    ("Center", "center"),
    ("Top Left", "top-left"), ("Top Right", "top-right"),
    ("Bottom Left", "bottom-left"), ("Bottom Right", "bottom-right"),
    ("First Third", "first-third"), ("Center Third", "center-third"),
    ("Last Third", "last-third"),
    ("Next Display", "next-display"),
  ]

  func enable() {
    guard statusItem == nil else { return }
    let hasT3 = FileManager.default.fileExists(atPath: T3TaskRegistry.directory.appendingPathComponent("statev2.sqlite").path)
    for segment in segments {
      UserDefaults.standard.register(defaults: ["msBar" + segment: segment != "T3" || hasT3])
    }
    refreshPreferences()
    refreshScale()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    item.autosaveName = "MachineSpiritCompact"
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self
    mainMenu = menu
    if let button = item.button {
      button.target = self
      button.action = #selector(showStatusMenu)
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      button.setAccessibilityLabel("MachineSpirit — stats, terminals and system controls")
      skullView = StatusSkullView(button: button)
    }
    system.onChange = { [weak self] in self?.updateStatusItemAppearance() }
    t3.changed = { [weak self] in self?.updateStatusItemAppearance() }
    system.enable()
    stats.onBarUpdate = { [weak self] in self?.updateStatusItemAppearance() }
    stats.onUpdate = { [weak self] rows in self?.updateStats(rows) }
    sample()
    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
    timer.tolerance = 0.5
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    if let button = item.button {
      appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
        self?.updateStatusItemAppearance()
      }
    }
    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .sink { [weak self] _ in self?.refreshPreferences() }.store(in: &cancellables)
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in
        self?.refreshScale()
        self?.updateStatusItemAppearance()
      }.store(in: &cancellables)
    Events.sink { [weak self] event in
      switch event {
      case .willActivate: self?.skullView?.setActive(true)
      case .willDeactivate: self?.skullView?.setActive(false)
      default: break
      }
    }.store(in: &cancellables)
    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
      .sink { [weak self] _ in self?.skullView?.refreshMotionPolicy() }.store(in: &cancellables)
    for name in [
      NSWorkspace.didMountNotification,
      NSWorkspace.didUnmountNotification,
      NSWorkspace.didRenameVolumeNotification,
    ] {
      NSWorkspace.shared.notificationCenter.publisher(for: name)
        .sink { [weak self] _ in
          guard let self, self.enabledSegments.contains("Disks") else { return }
          self.stats.sampleBarDisks(force: true)
        }.store(in: &cancellables)
    }
    let center = DistributedNotificationCenter.default()
    center.publisher(for: Notification.Name("com.machinespirit.leader.nav"))
      .sink { [weak self] notification in
        guard notification.userInfo?["state"] as? String == "shown",
              let path = notification.userInfo?["path"] as? String else { return }
        self?.skullView?.navigate(path)
      }.store(in: &cancellables)
    center.publisher(for: Notification.Name("com.machinespirit.leader.feedback"))
      .sink { [weak self] notification in
        guard let kind = notification.userInfo?["kind"] as? String else { return }
        self?.skullView?.feedback(kind)
      }.store(in: &cancellables)
  }

  private func refreshPreferences() {
    let enabled = Set(segments.filter { UserDefaults.standard.bool(forKey: "msBar" + $0) })
    guard enabled != enabledSegments else { return }
    enabledSegments = enabled
    updateStatusItemAppearance()
  }

  private func refreshScale() {
    backingScale = NSScreen.screens.reduce(CGFloat(1)) { max($0, $1.backingScaleFactor) }
  }

  private func sample() {
    if enabledSegments.contains("CPU") { stats.sampleCPU() }
    if enabledSegments.contains("Disks") { stats.sampleBarDisks() }
    if enabledSegments.contains("T3") { t3.refresh() }
    let now = ProcessInfo.processInfo.systemUptime
    if menuIsOpen || now >= nextSheolSample {
      nextSheolSample = now + 46
      sheol.sample()
    }
    if enabledSegments.contains("Memory") { pressure = MemoryPressure.read(barOnly: true) }
    stats.sampleBar(
      gpu: enabledSegments.contains("GPU"),
      temperature: enabledSegments.contains("Temperature"))
    heartbeat?()
    system.checkExpiry()
    updateStatusItemAppearance()
  }

  func disable() {
    timer?.invalidate()
    timer = nil
    system.disable()
    nowPlaying.close()
    stats.close()
    stats.stopBar()
    t3.changed = nil
    cancellables.removeAll()
    appearanceObservation = nil
    skullView?.removeFromSuperview()
    skullView = nil
    if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
    statusItem = nil
    lastRender = nil
  }

  func buildMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    let summary = NSMenuItem(title: "Stats: Measuring…", action: nil, keyEquivalent: "")
    summary.toolTip = "CPU · GPU · RAM used · hottest sensor · network · free disk · battery. Open for details."
    let statistics = NSMenu()
    statistics.autoenablesItems = false
    statistics.delegate = self
    summary.submenu = statistics
    statsMenu = statistics
    statsSummaryItem = summary
    menu.addItem(summary)
    statsRows.removeAll()
    for name in SystemStats.names {
      let row = NSMenuItem(title: name + ": Measuring…", action: nil, keyEquivalent: "")
      let details = NSMenu()
      details.autoenablesItems = false
      let pending = NSMenuItem(title: "Measuring…", action: nil, keyEquivalent: "")
      pending.isEnabled = false
      details.addItem(pending)
      row.submenu = details
      statsRows[name] = row
      statistics.addItem(row)
    }
    statistics.addItem(.separator())
    statistics.addItem(actionItem("Sample Network Activity by Process…", #selector(sampleNetworkProcesses)))
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "at.obdev.littlesnitch.networkmonitor") != nil {
      statistics.addItem(actionItem("Open Little Snitch Network Monitor…", #selector(openNetworkMonitor)))
    }
    statistics.addItem(actionItem("Latest Idle Review…", #selector(showIdleReview)))
    if enabledSegments.contains("T3") { t3.append(to: menu) }
    sheol.append(to: menu)
    system.appendBrightness(to: menu)
    menu.addItem(sectionHeader("Now Playing"))
    nowPlaying.append(to: menu)
    system.appendControls(to: menu)
    menu.addItem(.separator())
    let leader = NSMenuItem(title: "Leader Key", action: nil, keyEquivalent: "")
    let leaderMenu = NSMenu()
    leaderMenu.autoenablesItems = false
    leader.submenu = leaderMenu
    menu.addItem(leader)
    appendLeaderOptions(to: leaderMenu)
    menu.addItem(
      NSMenuItem(
        title: "Quit MachineSpirit Leader Key", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"))
  }

  private func appendLeaderOptions(to menu: NSMenu) {
    system.appendLeaderOptions(to: menu)
    sheol.appendTools(to: menu)
    menu.addItem(actionItem("About", #selector(showAbout)))
    menu.addItem(actionItem("Settings…", #selector(showPreferences), key: ","))
    menu.addItem(actionItem("Reload config", #selector(reloadConfig)))
    menu.addItem(actionItem("Show config in Finder", #selector(revealConfigFile)))
    let bar = NSMenuItem(title: "Menu bar", action: nil, keyEquivalent: "")
    let options = NSMenu()
    options.autoenablesItems = false
    for segment in segments {
      let row = actionItem(segment, #selector(toggleSegment(_:)))
      row.representedObject = "msBar" + segment
      row.state = UserDefaults.standard.bool(forKey: "msBar" + segment) ? .on : .off
      options.addItem(row)
    }
    bar.submenu = options
    menu.addItem(bar)
    let windows = NSMenuItem(title: "Rectangle — Windows", action: nil, keyEquivalent: "")
    let windowMenu = NSMenu()
    for entry in rectangleActions {
      let title = entry.title
      let row = actionItem(title, #selector(runRectangleAction(_:)))
      row.representedObject = entry.action
      windowMenu.addItem(row)
    }
    windowMenu.addItem(actionItem("Rectangle Settings…", #selector(openRectangleSettings)))
    windows.submenu = windowMenu
    menu.addItem(windows)
    let keys = NSMenuItem(title: "Karabiner — Keys", action: nil, keyEquivalent: "")
    let keyMenu = NSMenu()
    let status = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
    karabinerStatusItem = status
    keyMenu.addItem(status)
    let profile = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
    karabinerProfileItem = profile
    keyMenu.addItem(profile)
    keyMenu.addItem(actionItem("Open Karabiner Settings…", #selector(openKarabinerSettings)))
    keyMenu.delegate = self
    karabinerMenu = keyMenu
    keys.submenu = keyMenu
    menu.addItem(keys)
  }

  @objc private func toggleSegment(_ item: NSMenuItem) {
    guard let key = item.representedObject as? String else { return }
    let enabled = !UserDefaults.standard.bool(forKey: key)
    UserDefaults.standard.set(enabled, forKey: key)
    item.state = enabled ? .on : .off
    refreshPreferences()
  }

  func setSkullVisible(_ visible: Bool) {
    UserDefaults.standard.set(visible, forKey: "msBarSkull")
    refreshPreferences()
  }

  // MARK: - Menu construction helpers

  private func sectionHeader(_ title: String) -> NSMenuItem {
    if #available(macOS 14.0, *) {
      return NSMenuItem.msSectionHeader(title: title)
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

  @objc private func openNetworkMonitor() {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "at.obdev.littlesnitch.networkmonitor") {
      NSWorkspace.shared.open(url)
    }
  }

  @objc private func sampleNetworkProcesses() {
    CommandRunner.run("/usr/bin/nettop -P -n -x -d -L 2 -s 1 -J bytes_in,bytes_out", on: .global(qos: .utility)) { result in
      let rows = result.status == 0 ? NetStats.busyProcesses(result.output) : nil
      let message = rows.map { $0.isEmpty ? "No traffic in this sample." : $0.joined(separator: "\n") }
      self.showReport("Network traffic in the last second", message ?? "The network sample was unavailable.")
    }
  }

  @objc private func showIdleReview() {
    CommandRunner.run("\"$HOME/bin/ms\" pulse report --hours 24 --json", on: .global(qos: .utility)) { result in
      guard result.status == 0,
            let report = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any] else {
        self.showReport("Idle review unavailable", "Check that the ms command is installed in ~/bin.")
        return
      }
      guard let review = report["latestIdleReview"] as? [String: Any],
            let time = review["timestamp"] as? String, let date = ISO8601DateFormatter().date(from: time),
            let suggestions = review["suggestions"] as? [String] else {
        self.showReport("No idle review yet", "The hourly Pulse check needs ten minutes of inactivity. This view covers the last 24 hours.")
        return
      }
      self.showReport("Idle review · " + date.formatted(date: .abbreviated, time: .shortened),
                      suggestions.isEmpty ? "No suggestions in that sample." : suggestions.joined(separator: "\n\n"))
    }
  }

  private func showReport(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

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
    task.standardError = FileHandle.nullDevice
    do {
      try task.run()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      task.waitUntilExit()
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
    task.standardError = FileHandle.nullDevice
    do {
      try task.run()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      task.waitUntilExit()
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

  @objc private func showStatusMenu() {
    guard let item = statusItem, let menu = mainMenu else { return }
    nowPlaying.prepareForMenu()
    item.menu = menu
    item.button?.performClick(nil)
  }

  func menuWillOpen(_ menu: NSMenu) {
    if menu === mainMenu {
      menuIsOpen = true
      buildMenu(menu)
      if enabledSegments.contains("T3") { t3.refresh(force: true) }
      system.menuWillOpen()
      nowPlaying.open()
      stats.open()
    } else if menu === karabinerMenu {
      refreshKarabiner()
    } else if menu === statsMenu {
      stats.setDetailsVisible(true)
    }
  }

  func menuDidClose(_ menu: NSMenu) {
    if menu === mainMenu {
      menuIsOpen = false
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.menuIsOpen else { return }
        self.statusItem?.menu = nil
        self.statusItem?.button?.target = self
        self.statusItem?.button?.action = #selector(self.showStatusMenu)
      }
      stats.close()
      nowPlaying.close()
    } else if menu === statsMenu {
      stats.setDetailsVisible(false)
    }
  }

  /// Update existing rows, never rebuild the sheol controls under the pointer.
  private func updateStats(_ rows: [SystemStats.Row]) {
    let order = ["CPU", "GPU", "Memory", "Temperatures", "Network ↓/↑", "Disk", "Battery"]
    let title = order.compactMap { name in
      rows.first { $0.name == name }?.compactSummary
    }.joined(separator: " · ")
    if !title.isEmpty, statsSummaryItem?.title != title {
      statsSummaryItem?.title = title
      statsSummaryItem?.attributedTitle = NSAttributedString(
        string: title,
        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)])
    }
    for reading in rows {
      guard let row = statsRows[reading.name], let submenu = row.submenu else { continue }
      let title = reading.name + ": " + reading.summary
      if row.title != title { row.title = title }
      while submenu.numberOfItems > reading.details.count {
        submenu.removeItem(at: submenu.numberOfItems - 1)
      }
      for (index, title) in reading.details.enumerated() {
        if index == submenu.numberOfItems {
          let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
          item.isEnabled = false
          submenu.addItem(item)
        } else if let item = submenu.item(at: index), item.title != title {
          item.title = title
        }
      }
    }
  }

  private func updateStatusItemAppearance() {
    guard let button = statusItem?.button else { return }
    func enabled(_ segment: String) -> Bool { enabledSegments.contains(segment) }
    let usedPercent = pressure.hasUsage ? Int((100 * Double(pressure.used) / Double(pressure.total)).rounded()) : nil
    let state = CompactBarState(
      skull: enabled("Skull"),
      t3: enabled("T3") ? t3.counts : .hidden,
      cpu: .init(enabled: enabled("CPU"), value: stats.cpuPercent),
      gpu: .init(enabled: enabled("GPU"), value: stats.bar.gpu),
      memory: .init(enabled: enabled("Memory"), value: usedPercent),
      availablePercent: pressure.hasAvailablePercent ? pressure.availablePercent : nil,
      pressureLevel: enabled("Memory") && pressure.hasPressureLevel
        ? .init(rawValue: pressure.vmPressureLevel) : nil,
      temperature: .init(enabled: enabled("Temperature"), value: stats.bar.temperature),
      disks: enabled("Disks") ? stats.barDisks : [],
      awake: enabled("Awake") ? system.isAwake : nil,
      dark: button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
      scale: backingScale, height: NSStatusBar.system.thickness)
    let descriptions = state.descriptions(awakeStatus: system.awakeStatusText)
    let tip = (descriptions + ["Click for disk, network and details"]).joined(separator: "\n")
    if button.toolTip != tip {
      button.toolTip = tip
      button.setAccessibilityValue(descriptions.isEmpty ? nil : descriptions.joined(separator: ". "))
    }
    skullView?.configure(visible: state.skull, dark: state.dark, scale: state.scale)
    guard state != lastRender else { return }
    lastRender = state
    button.image = CompactBar.image(state)
    skullView?.align()
  }

}

// MARK: - Terminal and tmux menu section (no status item ownership)
final class SheolMenuSection: NSObject, NSMenuDelegate {
  private weak var menu: NSMenu?
  private let samplingQueue = DispatchQueue(label: "com.machinespirit.sheol", qos: .utility)
  private var sampling = false
  private var lastTerminalSample = -Double.infinity
  private var nativeTerminals: [TerminalReader.Terminal] = []
  private var nativeOtherTerminals: [TerminalReader.Terminal] = []

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
      let d = s / 86400
      let h = (s % 86400) / 3600
      let m = (s % 3600) / 60
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
    let job: String?  // foreground command (iTerm jobName)
    let procs: String?  // ALL commands on the tty — deep agent detection (job can hide it)
    var isHotkey: Bool { TerminalProtection.isHotkey(name: name) }
    var appName: String {
      id.hasPrefix("app:") ? String(id.dropFirst(4)) : "iTerm2"
    }
  }
  private var terminals: [Terminal] = []

  // Retains the ☠ BANISH ALL type-to-confirm panel while it's on screen.
  private var banishPanel: BanishAllPanel?

  /// The shared 2s heartbeat reads tmux's socket. Native terminal enumeration is
  /// throttled to 46s, matching the old 45s cost budget. Never attaches a client.
  func sample() {
    guard !sampling else { return }
    sampling = true
    let now = ProcessInfo.processInfo.systemUptime
    let refreshTerms = now - lastTerminalSample >= 46
    let itermPID = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.googlecode.iterm2"
    ).first?.processIdentifier
    let cached = nativeTerminals
    let otherCached = nativeOtherTerminals
    samplingQueue.async { [weak self] in
      let format =
        "S\u{1f}#{session_name}\u{1f}#{session_attached}\u{1f}#{session_created}\u{1f}#{session_activity}\u{1f}#{pane_current_command}"
      let result = TmuxReader.read([
        "list-sessions", "-F", format, ";", "list-panes", "-a", "-F", "P\u{1f}#{pane_tty}", ";",
        "list-clients", "-F", "P\u{1f}#{client_tty}",
      ])
      guard let self else { return }
      guard let result else {
        DispatchQueue.main.async { self.sampling = false }
        return
      }
      var spirits: [Spirit] = []
      var tmuxTTYs = Set<String>()
      for line in result.split(separator: "\n") {
        let fields = line.components(separatedBy: "\u{1f}")
        if fields.first == "P", fields.count == 2 { tmuxTTYs.insert(fields[1]) }
        if fields.first == "S", fields.count == 6 {
          spirits.append(
            Spirit(
              name: fields[1], attached: Int(fields[2]) ?? 0,
              created: Int(fields[3]) ?? 0, activity: Int(fields[4]) ?? 0, command: fields[5]))
        }
      }
      let terminals =
        refreshTerms
        ? (itermPID.flatMap { TerminalReader.readITerm(pid: $0) }
          ?? (itermPID == nil ? [] : cached)) : cached
      let excluded = tmuxTTYs.union(terminals.map(\.tty))
      let others = refreshTerms ? TerminalReader.otherTerminals(excluding: excluded) : otherCached
      let rows = (terminals + others).map {
        Terminal(
          id: $0.id, tty: $0.tty, name: $0.name,
          isTmux: tmuxTTYs.contains($0.tty) || $0.name.hasPrefix("tmux"), job: nil, procs: nil)
      }
      DispatchQueue.main.async {
        self.sampling = false
        if refreshTerms { self.lastTerminalSample = now }
        self.nativeTerminals = terminals
        self.nativeOtherTerminals = others
        self.spirits = spirits
        let enriched = Dictionary(
          self.terminals.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        self.terminals = rows.map { row in
          guard let old = enriched[row.id], old.job != nil else { return row }
          return Terminal(
            id: row.id, tty: row.tty, name: old.name, isTmux: row.isTmux, job: old.job,
            procs: old.procs)
        }
      }
    }
  }

  func refreshCounts() {
    refresh()
    refreshTerminals()
    lastTerminalSample = -Double.infinity
  }

  // MARK: - Data (the process runs off-main; UI mutates on main)

  private func refresh() {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      let fresh = Self.list(core: self.corePath)
      DispatchQueue.main.async {
        self.spirits = fresh
      }
    }
  }

  private func refreshTerminals() {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      let terms = Self.listTerminals(core: self.termPath)
      DispatchQueue.main.async {
        self.terminals = terms
        // Keep the open rows stable beside destructive controls; refresh on next open.
      }
    }
  }

  private static func list(core: String) -> [Spirit] {
    guard FileManager.default.isExecutableFile(atPath: core) else { return [] }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: core)
    task.arguments = ["list", "--json"]
    let out = Pipe()
    task.standardOutput = out
    task.standardError = FileHandle.nullDevice
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
    task.standardError = FileHandle.nullDevice
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

  func append(to menu: NSMenu) {
    self.menu = menu
    refreshCounts()

    let plainTerms = terminals.filter { !$0.isTmux }

    // Shared row width so the red ✕ (positioned at rowW-46) lines up across BOTH
    // the tmux and terminal sections. Each section keeps its own label width for
    // the name; only the overall row width is unified.
    let menuFont = NSFont.menuFont(ofSize: 0)
    let tmuxLabelW =
      spirits.isEmpty
      ? 0
      : min(360, ceil(spirits.map { Self.rowLabel(for: $0).size().width }.max() ?? 120) + 22)
    let termLabelW =
      plainTerms.isEmpty
      ? 0
      : min(
        360,
        ceil(
          plainTerms.map {
            NSAttributedString(
              string: "$|  ❯  " + $0.name.replacingOccurrences(of: "\n", with: " "),
              attributes: [.font: menuFont]
            ).size().width
          }.max() ?? 160))
    let rowW = max(tmuxLabelW, termLabelW) + 116  // marker + name + moon + agent + ✕ + pad

    // Freeze row order during tracking; destructive controls must not move under the pointer.
    func addSection(_ title: String, items: [NSMenuItem]) {
      menu.addItem(.separator())
      menu.addItem(.msSectionHeader(title: title))
      if items.isEmpty {
        let empty = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
        empty.isEnabled = false
        menu.addItem(empty)
      }
      for item in items.prefix(6) { menu.addItem(item) }
      if items.count > 6 {
        let more = NSMenuItem(title: "More…", action: nil, keyEquivalent: "")
        let overflow = NSMenu()
        overflow.autoenablesItems = false
        for item in items.dropFirst(6) { overflow.addItem(item) }
        more.submenu = overflow
        menu.addItem(more)
      }
    }
    let otherApps = Set(plainTerms.map(\.appName)).subtracting(["iTerm2", "Terminal"]).sorted()
    for app in ["iTerm2", "Terminal"] + otherApps {
      let items = plainTerms.filter { $0.appName == app }.sorted { $0.id < $1.id }.map { term in
        var label = term.name.replacingOccurrences(of: "\n", with: " ")
        if label.count > 52 { label = String(label.prefix(51)) + "…" }
        let isITerm = term.appName == "iTerm2"
        let agent = agentKind(for: [term.job, term.procs].compactMap { $0 }.joined(separator: " "))
        let item = NSMenuItem()
        item.view = TerminalRow(
          id: term.id, title: "❯  " + label, tty: term.tty,
          canKill: isITerm && !term.isHotkey, hotkey: term.isHotkey,
          marker: isITerm ? .iterm : .other,
          agent: agent, labelW: termLabelW, rowW: rowW, owner: self)
        return item
      }
      addSection(app, items: items)
    }
    for (title, detached) in [("tmux — living", false), ("sheol — detached", true)] {
      let items = spirits.filter { $0.isWandering == detached }.sorted {
        $0.activity == $1.activity ? $0.name < $1.name : $0.activity > $1.activity
      }.map { rowItem($0, labelW: tmuxLabelW, rowW: rowW) }
      addSection(title, items: items)
    }
    menu.addItem(.separator())
    menu.addItem(
      actionRow(title: "＋  New tmux window", rowW: rowW, action: #selector(newTmuxWindow)))
    menu.addItem(
      actionRow(title: "＋  New terminal window", rowW: rowW, action: #selector(newTerminalWindow)))
    let open = NSMenuItem(
      title: "Open sheol ledger…", action: #selector(openLedger), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    menu.addItem(.separator())
  }

  // This section is the delegate only for the Session snapshots submenu.
  func menuWillOpen(_ menu: NSMenu) {
    guard let header = menu.items.first else { return }
    let path = corePath
    DispatchQueue.global(qos: .utility).async {
      guard let age = Self.lastSaveAge(core: path) else { return }
      DispatchQueue.main.async { [weak header] in header?.title = "Snapshot — \(age)" }
    }
  }

  func appendTools(to menu: NSMenu) {
    let tools = NSMenuItem(title: "Session snapshots", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    submenu.autoenablesItems = false
    submenu.delegate = self
    addSurvivalSection(to: submenu)
    tools.submenu = submenu
    menu.addItem(tools)
  }

  /// Snapshot age + 💾 Save · ♻ Restore · ☠ BANISH ALL. Lives at the bottom of the
  /// menu so the destructive nuke is far from the per-session controls.
  private func addSurvivalSection(to menu: NSMenu) {
    let header = NSMenuItem(title: "Snapshot", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
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
  }

  @objc fileprivate func focusTerminalRow(_ sender: SheolRowButton) {
    menu?.cancelTracking()
    runTerm(["focus", sender.sessionName])
  }

  /// Close a terminal — the same triple-tap ward as killRow, calling
  /// terminals-core kill. The ledger stays open so you can close several; the
  /// retired row hides in place (a reopen rebuilds fresh regardless).
  @objc fileprivate func killTerminalRow(_ sender: SheolRowButton) {
    guard let terminal = terminals.first(where: { $0.id == sender.sessionName }),
      terminal.appName == "iTerm2", !terminal.isHotkey
    else {
      sender.resetWard()
      return
    }
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
    // Living (attached) → has a terminal → green $|; wandering → dim ▪.
    // Agent glyph flags a session whose command is a known agent CLI — and a
    // DETACHED spirit can still be running one (that's the point of tmux), so it
    // applies regardless of attach state.
    item.view = SheolRow(
      name: spirit.name, title: dot + spirit.name,
      subtitle: "   ·  \(spirit.command) · \(spirit.quietFor)",
      labelW: labelW, rowW: rowW, isWandering: spirit.isWandering,
      marker: spirit.isWandering ? .other : .iterm,
      agent: agentKind(for: spirit.command), owner: self)
    return item
  }

  private func sectionHeader(_ title: String) -> NSMenuItem {
    if #available(macOS 14.0, *) { return NSMenuItem.msSectionHeader(title: title) }
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  // Row actions. revive + detach dismiss the ledger, then act (both reversible).
  // kill (banish) is guarded by a triple-tap ward and deliberately keeps the
  // ledger open so you can banish several sessions in a row.
  @objc fileprivate func reviveRow(_ sender: SheolRowButton) {
    menu?.cancelTracking()
    runCore(["revive", sender.sessionName])
  }

  @objc fileprivate func detachRow(_ sender: SheolRowButton) {
    menu?.cancelTracking()
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

  /// Retire only the clicked row, including inside More…, without shifting controls.
  private func retireRow(_ button: SheolRowButton) {
    retireTerminalRow(button)
  }

  @objc private func openLedger() {
    guard FileManager.default.isExecutableFile(atPath: openerPath) else { return }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: openerPath)
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
  }

  // MARK: - New windows

  /// A full-width button as a custom menu-view item — clicking it does NOT dismiss
  /// the menu (unlike a plain NSMenuItem action), so you can spawn several windows
  /// in a row without the ledger closing.
  private func actionRow(title: String, rowW: CGFloat, action: Selector) -> NSMenuItem {
    let item = NSMenuItem()
    item.view = MenuActionRow(title: title, rowW: max(rowW, 200), target: self, action: action)
    return item
  }

  /// Run an executable off-main with ITERM_NO_ACTIVATE=1 so any iTerm window it
  /// opens stays in the BACKGROUND — no focus steal, so the menu stays open and
  /// you can make a bunch. (Leader Key's `t t` bind runs the same script WITHOUT
  /// this flag, so it still opens focused.)
  private func spawnBackground(_ path: String, _ args: [String] = []) {
    guard FileManager.default.isExecutableFile(atPath: path) else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      let task = Process()
      task.executableURL = URL(fileURLWithPath: path)
      task.arguments = args
      var env = ProcessInfo.processInfo.environment
      env["ITERM_NO_ACTIVATE"] = "1"
      task.environment = env
      task.standardOutput = FileHandle.nullDevice
      task.standardError = FileHandle.nullDevice
      try? task.run()
    }
  }

  /// ＋ New tmux window — a fresh protected session (evocative name) via
  /// tmux-launch.sh, the same thing the TUI's `n` and Leader Key's `t t` run.
  @objc private func newTmuxWindow() {
    spawnBackground(home.appendingPathComponent("bin/tmux-launch.sh").path)
  }

  /// ＋ New terminal window — a fresh iTerm2 window (terminals-core new).
  @objc private func newTerminalWindow() { spawnBackground(termPath, ["new"]) }

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
  /// missing. Resolve the tmux snapshot path on the utility queue.
  private static func lastSaveAge(core: String) -> String? {
    guard FileManager.default.isExecutableFile(atPath: core) else { return nil }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: core)
    task.arguments = ["last-save"]
    let out = Pipe()
    task.standardOutput = out
    task.standardError = FileHandle.nullDevice
    do {
      try task.run()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      task.waitUntilExit()
      let text = String(decoding: data, as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines)
      let epoch = Int(text) ?? 0
      if epoch == 0 { return "never saved" }
      let secs = max(0, Int(Date().timeIntervalSince1970) - epoch)
      let d = secs / 86400
      let h = (secs % 86400) / 3600
      let m = (secs % 3600) / 60
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
    let w: CGFloat = 400
    let h: CGFloat = 220
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
    let cw: CGFloat = 42
    let gap: CGFloat = 8
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

// MARK: - Agent awareness + terminal marker (shared by both row types)

/// A known agent CLI and the glyph that flags a session running it. Matched by a
/// substring of the session's running command / foreground job, so it fires
/// whether or not the tool is "installed" — the instant one runs, the row warns
/// you before you close it. Extend by adding a row to `agentTable`.
struct AgentKind {
  let glyph: String  // fallback text/emoji when there's no drawn mark
  let label: String
  var image: NSImage?  // a drawn mark (Claude's spark) — preferred over the glyph
}

/// Ordered; first substring match wins. Keys are lowercased and matched against
/// the tty's commands, so plain keywords are safe. Add agents here.
private let agentTable: [(key: String, glyph: String, label: String)] = [
  ("claude", "✳", "Claude Code"),
  ("codex", "🔷", "Codex"),
  ("grok", "🛰️", "Grok"),
  ("gemini", "✦", "Gemini CLI"),
  ("deepseek", "🐋", "DeepSeek"),
  ("kimi", "🌙", "Kimi"),
  ("qwen", "🐧", "Qwen Code"),
  ("aider", "🤝", "Aider"),
  ("opencode", "🤖", "opencode"),
  ("goose", "🪿", "Goose"),
  ("cursor-agent", "▮", "Cursor Agent"),
]

func agentKind(for command: String?) -> AgentKind? {
  guard let command, !command.isEmpty else { return nil }
  let c = command.lowercased()
  for row in agentTable where c.contains(row.key) {
    // Drawn marks for the agents that have them (stylized, brand-colored — Claude's
    // orange spark, Codex's rosette, Grok's slash); the rest fall back to a glyph.
    let image: NSImage?
    switch row.key {
    case "claude": image = claudeSparkMark
    case "codex": image = codexRosetteMark
    case "grok": image = grokSlashMark
    default: image = nil
    }
    return AgentKind(glyph: row.glyph, label: row.label, image: image)
  }
  return nil
}

/// Claude's mark: a radial spark in Anthropic's terracotta orange, drawn once and
/// reused. A functional indicator (not a pixel copy of the brand asset) — reads as
/// Claude at menu-row size.
let claudeSparkMark: NSImage = {
  let size: CGFloat = 13
  let img = NSImage(size: NSSize(width: size, height: size))
  img.lockFocus()
  let c = CGPoint(x: size / 2, y: size / 2)
  NSColor(srgbRed: 0.80, green: 0.44, blue: 0.31, alpha: 1).setStroke()  // Anthropic orange
  let rays = 11
  let r0 = size * 0.05
  let r1 = size * 0.46
  for i in 0..<rays {
    let a = CGFloat(i) / CGFloat(rays) * .pi * 2
    let p = NSBezierPath()
    p.lineWidth = size * 0.135
    p.lineCapStyle = .round
    p.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0))
    p.line(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
    p.stroke()
  }
  img.unlockFocus()
  return img
}()

/// Codex's mark: a six-fold rosette (an OpenAI-blossom feel). A template image, so
/// it adopts the menu's text color and stays legible in light and dark. A stylized
/// functional indicator, not a copy of the brand logo.
let codexRosetteMark: NSImage = {
  let size: CGFloat = 13
  let img = NSImage(size: NSSize(width: size, height: size))
  img.lockFocus()
  let c = CGPoint(x: size / 2, y: size / 2)
  NSColor.black.setStroke()
  let petals = 6
  let r = size * 0.30
  for i in 0..<petals {
    let a = CGFloat(i) / CGFloat(petals) * .pi * 2
    let pc = CGPoint(x: c.x + cos(a) * r * 0.62, y: c.y + sin(a) * r * 0.62)
    let p = NSBezierPath(
      ovalIn: NSRect(x: pc.x - r * 0.62, y: pc.y - r * 0.62, width: r * 1.24, height: r * 1.24))
    p.lineWidth = size * 0.08
    p.stroke()
  }
  img.unlockFocus()
  img.isTemplate = true
  return img
}()

/// Grok's mark: a stark angular slash (an xAI feel). Template image (light/dark
/// safe). A stylized functional indicator, not a copy of the brand logo.
let grokSlashMark: NSImage = {
  let size: CGFloat = 13
  let img = NSImage(size: NSSize(width: size, height: size))
  img.lockFocus()
  let c = CGPoint(x: size / 2, y: size / 2)
  NSColor.black.setStroke()
  let long = NSBezierPath()
  long.lineWidth = size * 0.15
  long.lineCapStyle = .round
  long.move(to: CGPoint(x: c.x - size * 0.28, y: c.y - size * 0.30))
  long.line(to: CGPoint(x: c.x + size * 0.30, y: c.y + size * 0.30))
  long.stroke()
  let tick = NSBezierPath()
  tick.lineWidth = size * 0.15
  tick.lineCapStyle = .round
  tick.move(to: CGPoint(x: c.x + size * 0.06, y: c.y - size * 0.30))
  tick.line(to: CGPoint(x: c.x + size * 0.30, y: c.y - size * 0.06))
  tick.stroke()
  img.unlockFocus()
  img.isTemplate = true
  return img
}()

/// The leading terminal marker: green `$|` (the iTerm dock-icon look) when a
/// session has an iTerm terminal, a dim `▪` otherwise (a detached tmux spirit or
/// a non-iTerm app). Baked into the row's name label as a colored prefix.
enum RowMarker {
  case iterm
  case other
  var glyph: String { self == .iterm ? "$|" : "▪" }
  var color: NSColor { self == .iterm ? .systemGreen : .tertiaryLabelColor }
}

/// A small non-interactive indicator for an agent — its drawn mark (Claude's
/// spark) if it has one, else its emoji glyph. Used in the trailing slot of both
/// row types. The caller sets the frame.
func agentIndicatorView(_ agent: AgentKind) -> NSView {
  if let image = agent.image {
    let iv = NSImageView()
    iv.image = image
    iv.imageScaling = .scaleProportionallyUpOrDown
    iv.toolTip = "\(agent.label) may be running here"
    return iv
  }
  let f = NSTextField(labelWithString: agent.glyph)
  f.alignment = .center
  f.font = .systemFont(ofSize: 13)
  f.toolTip = "\(agent.label) may be running here"
  return f
}

/// A full-width menu row that's a single button, WITHOUT the auto-dismiss a plain
/// NSMenuItem action has — so the "＋ New …" rows can be clicked repeatedly to spawn
/// several windows while the ledger stays open. Hover highlight matches the others.
private final class MenuActionRow: NSView {
  private let title: String
  private let button: NSButton
  private var hovered = false
  private var trackingArea: NSTrackingArea?

  init(title: String, rowW: CGFloat, target: AnyObject, action: Selector) {
    self.title = title
    let h: CGFloat = 22
    let b = NSButton(frame: NSRect(x: 6, y: 0, width: rowW - 12, height: h))
    b.isBordered = false
    b.alignment = .left
    b.attributedTitle = Self.label(title, hovered: false)
    b.target = target
    b.action = action
    self.button = b
    super.init(frame: NSRect(x: 0, y: 0, width: rowW, height: h))
    addSubview(b)
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
    button.attributedTitle = Self.label(title, hovered: h)
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard hovered else { return }
    NSColor.selectedContentBackgroundColor.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
  }

  static func label(_ title: String, hovered: Bool) -> NSAttributedString {
    NSAttributedString(
      string: title,
      attributes: [
        .foregroundColor: hovered ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
        .font: NSFont.menuFont(ofSize: 0),
      ])
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
    let glyphs =
      String(repeating: "◆", count: max(0, remaining))
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
  private let marker: RowMarker
  private let nameButton: SheolRowButton
  private let killButton: SheolRowButton?
  private var hovered = false
  private var trackingArea: NSTrackingArea?

  init(
    id: String, title: String, tty: String, canKill: Bool, hotkey: Bool = false, marker: RowMarker,
    agent: AgentKind?, labelW: CGFloat, rowW: CGFloat, owner: SheolMenuSection
  ) {
    self.title = title
    self.marker = marker
    let h: CGFloat = 22

    let focus = SheolRowButton(frame: NSRect(x: 6, y: 0, width: labelW, height: h))
    focus.sessionName = id
    focus.isBordered = false
    focus.imagePosition = .noImage
    focus.alignment = .left
    (focus.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    focus.attributedTitle = Self.label(title: title, marker: marker, hovered: false)
    focus.target = owner
    focus.action = #selector(SheolMenuSection.focusTerminalRow(_:))
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
      kill.action = #selector(SheolMenuSection.killTerminalRow(_:))
      self.killButton = kill
    } else {
      self.killButton = nil
    }

    super.init(frame: NSRect(x: 0, y: 0, width: rowW, height: h))
    addSubview(nameButton)
    if let killButton { addSubview(killButton) }
    if hotkey {
      let tag = NSTextField(labelWithString: "hotkey")
      tag.font = .systemFont(ofSize: 9, weight: .medium)
      tag.textColor = .secondaryLabelColor
      tag.alignment = .center
      tag.frame = NSRect(x: rowW - 46, y: 5, width: 40, height: 13)
      addSubview(tag)
    }
    // Agent glyph — flags an agent CLI running in this terminal, just left of the
    // ✕ (the safety cue before you close it).
    if let agent {
      let g = agentIndicatorView(agent)
      g.frame = NSRect(x: rowW - 70, y: 0, width: 24, height: h)
      addSubview(g)
    }
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
    nameButton.attributedTitle = Self.label(title: title, marker: marker, hovered: h)
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard hovered else { return }
    NSColor.selectedContentBackgroundColor.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
  }

  static func label(title: String, marker: RowMarker, hovered: Bool) -> NSAttributedString {
    let s = NSMutableAttributedString(
      string: marker.glyph + "  ",
      attributes: [
        .foregroundColor: hovered ? NSColor.selectedMenuItemTextColor : marker.color,
        .font: NSFont.menuFont(ofSize: 0),
      ])
    s.append(
      NSAttributedString(
        string: title,
        attributes: [
          .foregroundColor: hovered ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
          .font: NSFont.menuFont(ofSize: 0),
        ]))
    return s
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
  private let marker: RowMarker
  private let nameButton: SheolRowButton
  private let detachButton: SheolRowButton?
  private let killButton: SheolRowButton
  private var hovered = false
  private var trackingArea: NSTrackingArea?

  init(
    name: String, title: String, subtitle: String, labelW: CGFloat, rowW: CGFloat,
    isWandering: Bool, marker: RowMarker, agent: AgentKind?, owner: SheolMenuSection
  ) {
    self.isWandering = isWandering
    self.title = title
    self.subtitle = subtitle
    self.marker = marker
    let h: CGFloat = 22

    // Name — borderless button sized to the measured label (no clipping). The
    // leading terminal marker ($| / ▪) is baked in as a colored prefix.
    let revive = SheolRowButton(frame: NSRect(x: 6, y: 0, width: labelW, height: h))
    revive.sessionName = name
    revive.isBordered = false
    revive.imagePosition = .noImage
    revive.alignment = .left
    (revive.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    revive.attributedTitle = Self.label(
      title: title, subtitle: subtitle, marker: marker, hovered: false)
    revive.target = owner
    revive.action = #selector(SheolMenuSection.reviveRow(_:))
    revive.toolTip =
      isWandering
      ? "Revive — reattach in a new iTerm window"
      : "Open another window attached to this session"
    self.nameButton = revive

    // Kill (banish) — the ✕, in red; wider than a plain icon so the ◆◆◇ ward
    // fits when armed. Triple-tap handled in SheolMenuSection.killRow.
    let kill = Self.icon("xmark.circle.fill", name: name, tip: "Banish — tap 3× (◆◆◇ ward)")
    kill.contentTintColor = .systemRed
    kill.frame = NSRect(x: rowW - 46, y: 1, width: 40, height: 20)
    kill.target = owner
    kill.action = #selector(SheolMenuSection.killRow(_:))
    self.killButton = kill

    // Detach (the sleepy moon) — only on a living, attached session. Sits left of
    // the agent-glyph slot.
    if !isWandering {
      let detach = Self.icon("moon.zzz", name: name, tip: "Send to sheol (detach)")
      detach.frame = NSRect(x: rowW - 96, y: 1, width: 22, height: 20)
      detach.target = owner
      detach.action = #selector(SheolMenuSection.detachRow(_:))
      self.detachButton = detach
    } else {
      self.detachButton = nil
    }

    super.init(frame: NSRect(x: 0, y: 0, width: rowW, height: h))
    addSubview(nameButton)
    addSubview(killButton)
    if let detachButton { addSubview(detachButton) }
    // Agent glyph — flags that an agent CLI may be running, just left of the ✕
    // (the safety cue before you banish). Non-interactive; tooltip names it.
    if let agent {
      let g = agentIndicatorView(agent)
      g.frame = NSRect(x: rowW - 70, y: 0, width: 24, height: h)
      addSubview(g)
    }
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
    nameButton.attributedTitle = Self.label(
      title: title, subtitle: subtitle, marker: marker, hovered: h)
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

  static func label(title: String, subtitle: String, marker: RowMarker, hovered: Bool)
    -> NSAttributedString
  {
    let nameColor: NSColor = hovered ? .selectedMenuItemTextColor : .labelColor
    let subColor: NSColor = hovered ? .selectedMenuItemTextColor : .secondaryLabelColor
    let s = NSMutableAttributedString(
      string: marker.glyph + "  ",
      attributes: [
        .foregroundColor: hovered ? NSColor.selectedMenuItemTextColor : marker.color,
        .font: NSFont.menuFont(ofSize: 0),
      ])
    s.append(
      NSAttributedString(
        string: title,
        attributes: [.foregroundColor: nameColor, .font: NSFont.menuFont(ofSize: 0)]))
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
