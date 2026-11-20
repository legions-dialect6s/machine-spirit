import Cocoa

/// Future browser-extension seam. Only a companion extension can supply audible
/// tab identity/title/domain and an activation token. Nest those rows under the
/// owning browser here; CoreAudio process IDs are NOT tab IDs. No fake tab rows.
struct NowPlayingBrowserTab {
  let id: String
  let title: String
  let domain: String
  let activate: () -> Void
}
protocol NowPlayingBrowserTabProvider: AnyObject {
  func audibleTabs(for bundleIdentifier: String) -> [NowPlayingBrowserTab]
}

final class NowPlayingMenuSection: NSObject {
  struct AppRow {
    let app: NSRunningApplication?
    let pid: pid_t
    let name: String
    var levels: [NowPlayingLevel]
  }
  private weak var menu: NSMenu?
  private var items: [NSMenuItem] = []
  private var rowViews: [NowPlayingRowView] = []
  private let queue = DispatchQueue(label: "com.machinespirit.now-playing", qos: .utility)
  private let capturePolicy = NowPlayingCapturePolicy()
  private var session: NowPlayingAudioSession?
  private var processTimer: Timer?
  private var meterTimer: Timer?
  private var generation = 0
  private var sampling = false
  private(set) var rows: [AppRow] = []
  private(set) var isOpen = false
  private(set) var sampleCount = 0
  private(set) var metersUnavailable = false
  private(set) var enumerationFailed = false
  private var lastRowKeys: [String] = []
  // Injection is also used by the standalone smoke harness for deterministic
  // denial and close-during-enumeration tests. Production uses CoreAudio.
  var enumerate: () throws -> [NowPlayingProcess] = nowPlayingProcesses
  var makeTap: NowPlayingAudioSession.TapFactory?

  func append(to menu: NSMenu) {
    self.menu = menu
    items.removeAll()
    rowViews.removeAll()
    lastRowKeys.removeAll()
    menu.addItem(.separator())
    menu.addItem(.msSectionHeader(title: "Now Playing"))
    let item = NSMenuItem(title: "Checking audio…", action: nil, keyEquivalent: "")
    item.isEnabled = false
    menu.addItem(item)
    items = [item]
  }

  func open() {
    precondition(Thread.isMainThread)
    guard !isOpen else { return }
    guard #available(macOS 14.4, *) else {
      items.first?.title = "Requires macOS 14.4"
      return
    }
    isOpen = true
    generation += 1
    session = NowPlayingAudioSession(
      queue: queue, policy: capturePolicy, enumerate: enumerate, makeTap: makeTap)
    sample()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
    timer.tolerance = 0.1
    processTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func sample() {
    guard isOpen, !sampling, let session else { return }
    sampling = true
    let current = generation
    session.sample { [weak self] snapshot in
      // Explicit common-mode delivery works even inside NSMenu tracking.
      RunLoop.main.perform(inModes: [.common]) { [weak self] in
        guard let self, self.isOpen, self.generation == current else { return }
        self.sampling = false
        self.sampleCount += 1
        self.apply(snapshot)
      }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
  }

  private func apply(_ snapshot: NowPlayingAudioSession.Snapshot) {
    let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    var grouped: [pid_t: AppRow] = [:]
    for process in snapshot.processes {
      let app = nowPlayingOwner(
        NSRunningApplication(processIdentifier: process.pid), regular: regular)
      let pid = app?.processIdentifier ?? process.pid
      var row =
        grouped[pid]
        ?? AppRow(app: app, pid: pid, name: app?.localizedName ?? "Process \(pid)", levels: [])
      if let level = snapshot.levels[process.object] { row.levels.append(level) }
      grouped[pid] = row
    }
    rows = grouped.values.sorted {
      let order = $0.name.localizedCaseInsensitiveCompare($1.name)
      return order == .orderedSame ? $0.pid < $1.pid : order == .orderedAscending
    }
    metersUnavailable = snapshot.metersUnavailable
    enumerationFailed = snapshot.enumerationFailed
    renderRows()
    if rows.contains(where: { !$0.levels.isEmpty }) {
      if meterTimer == nil {
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
          self?.redrawMeters()
        }
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
      }
      redrawMeters()
    } else {
      meterTimer?.invalidate()
      meterTimer = nil
    }
  }

  private func renderRows() {
    guard let menu else { return }
    // Keep the menu items stable while tracking unless membership changes.
    let keys =
      rows.map { "\($0.pid):\($0.name):\(!$0.levels.isEmpty)" } + [
        "\(metersUnavailable):\(enumerationFailed)"
      ]
    if keys == lastRowKeys {
      for (index, row) in rows.enumerated() {
        rowViews[index].levels = row.levels
        items[index].representedObject = row.app
        items[index].isEnabled = row.app != nil
      }
      return
    }
    lastRowKeys = keys
    for item in items where item.menu === menu { menu.removeItem(item) }
    items.removeAll()
    rowViews.removeAll()
    for row in rows {
      let item = NSMenuItem(title: row.name, action: #selector(activate(_:)), keyEquivalent: "")
      item.target = self
      // Retain the original app object to avoid activating a reused PID.
      item.representedObject = row.app
      item.isEnabled = row.app != nil
      let view = NowPlayingRowView(name: row.name, icon: row.app?.icon, levels: row.levels)
      item.view = view
      menu.addItem(item)
      items.append(item)
      rowViews.append(view)
    }
    if rows.isEmpty {
      appendDisabled(enumerationFailed ? "Audio temporarily unavailable" : "silence", to: menu)
    }
    if metersUnavailable && !rows.isEmpty {
      appendDisabled("meters need System Audio Recording permission", to: menu)
    }
  }

  private func appendDisabled(_ title: String, to menu: NSMenu) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    menu.addItem(item)
    items.append(item)
  }
  private func redrawMeters() {
    guard isOpen else { return }
    for view in rowViews { view.updateLevel() }
  }
  @objc private func activate(_ sender: NSMenuItem) {
    guard let app = sender.representedObject as? NSRunningApplication, !app.isTerminated else {
      return
    }
    app.activate(options: [])
  }
  var timersAreNil: Bool { processTimer == nil && meterTimer == nil }
  var sessionIsNil: Bool { session == nil }

  /// Completion runs on the worker queue after taps, devices and IOProcs are
  /// nil. There is no synchronous CoreAudio work on the calling main thread.
  func close(_ completion: (() -> Void)? = nil) {
    precondition(Thread.isMainThread)
    isOpen = false
    generation += 1
    processTimer?.invalidate()
    processTimer = nil
    meterTimer?.invalidate()
    meterTimer = nil
    let old = session
    session = nil
    sampling = false
    rows.removeAll()
    for view in rowViews { view.levels.removeAll() }
    if let old { old.close(completion) } else { completion?() }
    assert(timersAreNil && sessionIsNil)
  }
  deinit {
    processTimer?.invalidate()
    meterTimer?.invalidate()
    session?.close()
  }
}

/// A menu view keeps native menu actions/keyboard navigation and supplies mouse
/// handling because NSMenu does not dispatch actions for a custom item's view.
final class NowPlayingRowView: NSView {
  private let name: String
  private let icon: NSImage?
  var levels: [NowPlayingLevel]
  private var rms: Float = 0
  private var peak: Float = 0
  private var tracking: NSTrackingArea?
  private var hovered = false
  override var isFlipped: Bool { true }

  init(name: String, icon: NSImage?, levels: [NowPlayingLevel]) {
    self.name = name
    self.icon = icon
    self.levels = levels
    super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
    autoresizingMask = [.width]
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Activate \(name)")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func updateTrackingAreas() {
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
    super.updateTrackingAreas()
  }
  override func mouseEntered(with event: NSEvent) {
    hovered = true
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    hovered = false
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    performAction()
  }
  override func accessibilityPerformPress() -> Bool { performAction() }
  @discardableResult private func performAction() -> Bool {
    guard let item = enclosingMenuItem, item.isEnabled, let menu = item.menu,
      let action = item.action
    else { return false }
    menu.cancelTracking()
    return NSApp.sendAction(action, to: item.target, from: item)
  }
  func updateLevel() {
    let values = levels.map(\.levels)
    // A browser can own multiple audio helpers: show the strongest helper,
    // rather than claiming separate processes form a phase-coherent mix.
    let nextRMS = values.map(\.rms).max() ?? 0
    let nextPeak = values.map(\.peak).max() ?? 0
    if nextRMS != rms || nextPeak != peak || enclosingMenuItem?.isHighlighted == true {
      rms = nextRMS
      peak = nextPeak
      needsDisplay = true
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    let highlighted =
      (hovered || enclosingMenuItem?.isHighlighted == true) && enclosingMenuItem?.isEnabled != false
    if highlighted {
      NSColor.selectedContentBackgroundColor.setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
    let fallback = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
    let image = icon ?? fallback
    image?.draw(
      in: NSRect(x: 14, y: 6, width: 16, height: 16), from: .zero, operation: .sourceOver,
      fraction: 1, respectFlipped: true, hints: nil)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let meterWidth: CGFloat = levels.isEmpty ? 0 : 66
    (name as NSString).draw(
      in: NSRect(x: 38, y: 5, width: bounds.width - 54 - meterWidth, height: 19),
      withAttributes: [
        .font: NSFont.menuFont(ofSize: 13),
        .foregroundColor: highlighted
          ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
        .paragraphStyle: paragraph,
      ])
    guard !levels.isEmpty else { return }
    let bar = NSRect(x: bounds.width - 72, y: 11, width: 56, height: 6)
    NSColor.labelColor.withAlphaComponent(0.12).setFill()
    NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
    // -60…0 dBFS gives quiet streams useful visual range. Amber is peak
    // >= -3 dBFS, not a fabricated indication of device output volume.
    let fraction = rms > 0 ? max(0, min(1, (20 * log10(Double(rms)) + 60) / 60)) : 0
    if fraction > 0 {
      (peak >= 0.708 ? NSColor.systemOrange : NSColor.systemGreen).setFill()
      NSBezierPath(
        roundedRect: NSRect(
          x: bar.minX, y: bar.minY, width: max(2, bar.width * fraction), height: bar.height),
        xRadius: 3, yRadius: 3
      ).fill()
    }
  }
}
