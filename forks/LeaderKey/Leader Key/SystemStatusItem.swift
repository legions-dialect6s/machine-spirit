import Cocoa
import os.log

final class SystemMenuSection: NSObject {
  private weak var displayMenu: NSMenu?
  private weak var awakeItem: NSMenuItem?
  private weak var syncItem: NSMenuItem?
  private weak var keysItem: NSMenuItem?
  var onChange: (() -> Void)?
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
  func checkExpiry() {
    awake.checkExpiry()
    updateAwake()
  }

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
    sessionItems.removeAll()
    let displays = NSMenu()
    displays.autoenablesItems = false
    displayMenu = displays
    let item = NSMenuItem(title: "Brightness", action: nil, keyEquivalent: "")
    item.submenu = displays
    let row = BrightnessMenuRow(display: nil, inline: true) { [weak self] value in
      self?.brightness.setAll(value)
    }
    row.updateMaster(brightness.masterLevel)
    row.openDetails = { [weak displays, weak row] in
      guard let row else { return }
      displays?.popUp(positioning: nil, at: NSPoint(x: row.bounds.maxX, y: row.bounds.maxY), in: row)
    }
    masterRow = row
    item.view = row
    menu.addItem(item)
    buildDisplays()

    let awakeRow = NSMenuItem(title: "Keep awake", action: nil, keyEquivalent: "")
    let awakeMenu = NSMenu()
    awakeMenu.autoenablesItems = false
    awakeRow.submenu = awakeMenu
    awakeItem = awakeRow
    menu.addItem(awakeRow)
    appendAwake(to: awakeMenu)
    let clipboard = add("Clipboard history…", action: #selector(openClipboard), to: menu)
    clipboard.keyEquivalent = "v"
    clipboard.keyEquivalentModifierMask = [.command, .shift]
    updateAwake()
  }

  private func appendAwake(to menu: NSMenu) {
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
  }

  private func buildDisplays() {
    guard let menu = displayMenu else { return }
    menu.removeAllItems()
    rows.removeAll()
    syncItem = add(
      "Sync all displays", action: #selector(toggleSync(_:)), to: menu, checked: brightness.sync)
    for display in brightness.displays {
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
    keysItem = keys
    let conflict = add(
      "Quit MonitorControl (conflicts)", action: #selector(quitMonitorControl), to: menu)
    conflict.isEnabled = !NSRunningApplication.runningApplications(
      withBundleIdentifier: "app.monitorcontrol.MonitorControl"
    ).isEmpty
  }

  func appendLeaderOptions(to menu: NSMenu) {
    let clear = add("Clear clipboard history", action: #selector(clearHistory), to: menu)
    clear.toolTip = "Remove unpinned clipboard entries; pinned entries are kept."
    _ = add("Open machine-spirit board", action: #selector(openBoard), to: menu)
    _ = add(
      "Graph overlay while typing", action: #selector(toggleOverlay(_:)), to: menu,
      checked: UserDefaults.standard.bool(forKey: "msGraphOverlayEnabled"))
  }

  private func updateAwake() {
    let state: String
    if let deadline = awake.deadline {
      let minutes = max(0, Int(ceil(deadline.timeIntervalSinceNow / 60)))
      state = minutes >= 60
        ? "\(minutes / 60)h" + (minutes % 60 == 0 ? "" : " \(minutes % 60)m") + " left"
        : "\(minutes)m left"
    } else {
      state = isAwake ? "indefinitely" : "off"
    }
    awakeItem?.title = "Keep awake: " + state
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
    masterRow?.updateMaster(brightness.masterLevel)
    let ids = Set(brightness.displays.map { $0.id })
    let changedDisplays = brightness.displays.contains { rows[$0.id]?.display !== $0 }
    if ids != Set(rows.keys) || changedDisplays {
      buildDisplays()
    } else {
      for display in brightness.displays { rows[display.id]?.update(display) }
    }
    syncItem?.state = brightness.sync ? .on : .off
    keysItem?.title = (brightness.sync
      ? "Brightness keys control all displays" : "Brightness keys control external under mouse")
      + (brightness.keysAvailable ? "" : " (needs Accessibility)")
    keysItem?.isEnabled = brightness.keysAvailable
  }

  @objc private func toggleSync(_ item: NSMenuItem) {
    brightness.sync.toggle()
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
  private let inline: Bool
  var openDetails: (() -> Void)?

  init(display: BrightnessController.Display?, inline: Bool = false, changed: @escaping (Double) -> Void) {
    self.inline = inline
    self.changed = changed
    self.display = display
    super.init(frame: NSRect(x: 0, y: 0, width: 360, height: inline ? 28 : 52))
    label.frame = NSRect(x: 16, y: 28, width: 328, height: 18)
    label.font = .menuFont(ofSize: 0)
    label.lineBreakMode = .byTruncatingTail
    slider.frame = NSRect(x: 16, y: 5, width: 328, height: 20)
    slider.isContinuous = true
    slider.target = self
    slider.action = #selector(slid)
    slider.setAccessibilityLabel("\(display?.screen.localizedName ?? "All displays") brightness")
    if inline {
      let details = NSButton(title: "Brightness", target: self, action: #selector(showDetails))
      details.isBordered = false
      details.alignment = .left
      details.font = .menuFont(ofSize: 0)
      details.frame = NSRect(x: 16, y: 3, width: 90, height: 22)
      addSubview(details)
      let arrow = NSButton(title: "›", target: self, action: #selector(showDetails))
      arrow.isBordered = false
      arrow.frame = NSRect(x: 328, y: 3, width: 22, height: 22)
      arrow.autoresizingMask = [.minXMargin]
      arrow.setAccessibilityLabel("Display brightness options")
      addSubview(arrow)
      slider.frame = NSRect(x: 112, y: 4, width: 204, height: 20)
      slider.autoresizingMask = [.width]
    } else {
      addSubview(label)
    }
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

  @objc private func showDetails() { openDetails?() }
  @objc private func slid() { changed(slider.doubleValue) }
}
