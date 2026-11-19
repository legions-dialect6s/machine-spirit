import Cocoa
import os.log

final class SystemMenuSection: NSObject {
  private weak var menu: NSMenu?
  var onChange: (() -> Void)?
  var rebuild: (() -> Void)?
  var isAwake: Bool { awake.minutes != 0 }
  private let awake = KeepAwake()
  private let brightness = BrightnessController()
  private var masterRow: BrightnessMenuRow?
  private var rows: [CGDirectDisplayID: BrightnessMenuRow] = [:]
  private let durations = [
    (0, "Off"), (-1, "Indefinitely"), (15, "15 min"),
    (60, "1 hour"), (120, "2 hours"), (240, "4 hours"), (480, "8 hours"),
  ]
  private var sessionItems: [Int: NSMenuItem] = [:]
  var showClipboard: (() -> Void)?
  var clearClipboard: (() -> Void)?
  var overlayChanged: (() -> Void)?

  static func registerDefaults() {
    UserDefaults.standard.register(defaults: [
      "msKeepAwakeDisplay": true, "msKeepAwakeAtLaunch": false,
      "msBrightnessKeysEnabled": true, "msGraphOverlayEnabled": true,
      "msLaunchBoardAtLogin": true, "msBrightnessSync": true,
    ])
  }

  func enable() {
    Self.registerDefaults()
    awake.onChange = { [weak self] in
      self?.updateAwake()
      self?.onChange?()
    }
    brightness.onChange = { [weak self] in self?.updateDisplays() }
    brightness.start()
    if UserDefaults.standard.bool(forKey: "msKeepAwakeAtLaunch") { awake.start(minutes: -1) }
  }

  func disable() {
    awake.stop()
    brightness.stop()
  }
  func checkExpiry() { awake.checkExpiry() }

  func menuWillOpen() {
    brightness.installTap()
    brightness.refresh()
  }

  private func add(_ title: String, action: Selector?, to menu: NSMenu, checked: Bool = false)
    -> NSMenuItem
  {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = action != nil
    item.state = checked ? .on : .off
    menu.addItem(item)
    return item
  }

  func append(to menu: NSMenu) {
    self.menu = menu
    sessionItems.removeAll()
    rows.removeAll()
    menu.addItem(.msSectionHeader(title: "Keep awake"))
    for (minutes, title) in durations {
      let item = add(title, action: #selector(selectDuration(_:)), to: menu)
      item.tag = minutes
      sessionItems[minutes] = item
    }
    _ = add(
      "Keep display on too", action: #selector(toggleDisplay(_:)), to: menu,
      checked: awake.keepsDisplayOn)
    _ = add(
      "Keep awake at launch", action: #selector(toggleLaunch(_:)), to: menu,
      checked: UserDefaults.standard.bool(forKey: "msKeepAwakeAtLaunch"))
    menu.addItem(.msSectionHeader(title: "Displays"))
    _ = add(
      "Sync all displays", action: #selector(toggleSync(_:)), to: menu, checked: brightness.sync)
    masterRow = nil
    if brightness.sync {
      let item = NSMenuItem()
      let row = BrightnessMenuRow(display: nil) { [weak self] value in
        self?.brightness.setAll(value)
      }
      row.updateMaster(brightness.masterLevel)
      masterRow = row
      item.view = row
      menu.addItem(item)
    }
    for display in brightness.displays where !brightness.sync {
      let item = NSMenuItem()
      let row = BrightnessMenuRow(display: display) { [weak self, weak display] value in
        guard let display else { return }
        self?.brightness.set(display, percent: value)
      }
      item.view = row
      rows[display.id] = row
      menu.addItem(item)
    }
    if brightness.displays.isEmpty { _ = add("No displays", action: nil, to: menu) }
    let title =
      (brightness.sync
        ? "Brightness keys control all displays" : "Brightness keys control external under mouse")
      + (brightness.keysAvailable ? "" : " (needs Accessibility)")
    let keys = add(
      title, action: #selector(toggleKeys(_:)), to: menu, checked: brightness.keysEnabled)
    keys.isEnabled = brightness.keysAvailable
    let conflict = add(
      "Quit MonitorControl (conflicts)", action: #selector(quitMonitorControl), to: menu)
    conflict.isEnabled = !NSRunningApplication.runningApplications(
      withBundleIdentifier: "app.monitorcontrol.MonitorControl"
    ).isEmpty
    _ = add("Clipboard history…", action: #selector(openClipboard), to: menu)
    let clear = add("Clear history", action: #selector(clearHistory), to: menu)
    clear.toolTip = "Remove unpinned clipboard entries; pinned entries are kept."
    updateAwake()
  }

  func appendLeaderOptions(to menu: NSMenu) {
    _ = add("Open machine-spirit board", action: #selector(openBoard), to: menu)
    _ = add(
      "Graph overlay while typing", action: #selector(toggleOverlay(_:)), to: menu,
      checked: UserDefaults.standard.bool(forKey: "msGraphOverlayEnabled"))
  }

  private func updateAwake() {
    for (minutes, title) in durations {
      sessionItems[minutes]?.state = awake.minutes == minutes ? .on : .off
      var label = title
      if minutes == awake.minutes, let deadline = awake.deadline {
        let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow / 60)))
        label += " (\(remaining) min remaining)"
      }
      sessionItems[minutes]?.title = label
    }
  }

  private func updateDisplays() {
    if brightness.sync {
      if let masterRow {
        masterRow.updateMaster(brightness.masterLevel)
      } else if self.menu != nil {
        rebuild?()
      }
      return
    }
    let ids = Set(brightness.displays.map { $0.id })
    let changedDisplays = brightness.displays.contains { rows[$0.id]?.display !== $0 }
    if ids != Set(rows.keys) || changedDisplays, self.menu != nil {
      rebuild?()
    } else {
      for display in brightness.displays { rows[display.id]?.update(display) }
    }
  }

  @objc private func toggleSync(_ item: NSMenuItem) {
    brightness.sync.toggle()
    if self.menu != nil { rebuild?() }
  }
  @objc private func quitMonitorControl() {
    NSRunningApplication.runningApplications(
      withBundleIdentifier: "app.monitorcontrol.MonitorControl"
    ).forEach { $0.terminate() }
  }
  @objc private func selectDuration(_ item: NSMenuItem) { awake.start(minutes: item.tag) }
  @objc private func toggleDisplay(_ item: NSMenuItem) {
    awake.keepsDisplayOn.toggle()
    item.state = awake.keepsDisplayOn ? .on : .off
  }
  @objc private func toggleLaunch(_ item: NSMenuItem) {
    toggleDefault("msKeepAwakeAtLaunch", item: item)
  }
  @objc private func toggleKeys(_ item: NSMenuItem) {
    brightness.keysEnabled.toggle()
    item.state = brightness.keysEnabled ? .on : .off
  }
  @objc private func toggleOverlay(_ item: NSMenuItem) {
    toggleDefault("msGraphOverlayEnabled", item: item)
    overlayChanged?()
  }
  private func toggleDefault(_ key: String, item: NSMenuItem) {
    let value = !UserDefaults.standard.bool(forKey: key)
    UserDefaults.standard.set(value, forKey: key)
    item.state = value ? .on : .off
  }
  @objc private func openClipboard() { showClipboard?() }
  @objc private func clearHistory() { clearClipboard?() }
  @objc private func openBoard() {
    guard let url = URL(string: "machinespirit://board") else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open(url, configuration: configuration)
  }
}

private final class BrightnessMenuRow: NSView {
  let display: BrightnessController.Display?
  private let label = NSTextField(labelWithString: "")
  private let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
  private let changed: (Double) -> Void

  init(display: BrightnessController.Display?, changed: @escaping (Double) -> Void) {
    self.changed = changed
    self.display = display
    super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 52))
    label.frame = NSRect(x: 16, y: 28, width: 328, height: 18)
    label.font = .menuFont(ofSize: 0)
    label.lineBreakMode = .byTruncatingTail
    slider.frame = NSRect(x: 16, y: 5, width: 328, height: 20)
    slider.isContinuous = true
    slider.target = self
    slider.action = #selector(slid)
    slider.setAccessibilityLabel("\(display?.screen.localizedName ?? "All displays") brightness")
    addSubview(label)
    addSubview(slider)
    if let display { update(display) }
  }

  required init?(coder: NSCoder) { nil }

  func update(_ display: BrightnessController.Display) {
    label.stringValue =
      display.screen.localizedName
      + (display.checked ? (display.available ? "" : " (software only)") : " (checking…)")
    slider.isEnabled = display.checked
    slider.doubleValue = display.percent
  }

  func updateMaster(_ value: Double) {
    label.stringValue = "All displays"
    slider.doubleValue = value
  }

  @objc private func slid() { changed(slider.doubleValue) }
}
