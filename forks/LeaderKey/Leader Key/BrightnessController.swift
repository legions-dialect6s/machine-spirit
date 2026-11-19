import Cocoa
import os.log

/// AppKit/state/gamma on main; independent serial I/O and trailing writes per display.
final class BrightnessController {
  final class Display {
    let id: CGDirectDisplayID
    let screen: NSScreen
    let builtIn: Bool
    let queue: DispatchQueue
    let hardware = DisplayHardware()
    let preferenceKey: String
    var service: CFTypeRef?
    var percent: Double = 100
    var maximum: UInt16 = 100
    var available = false  // hardware support; software remains available regardless
    var checked = false
    var revision = 0
    var reading = false
    var writing = false
    var pending: Double?
    var gamma: Double = 1

    init(screen: NSScreen) {
      self.screen = screen
      id =
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint32Value ?? 0
      builtIn = CGDisplayIsBuiltin(id) != 0
      queue = DispatchQueue(label: "com.machinespirit.brightness.\(id)", qos: .userInitiated)
      let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
      preferenceKey =
        "msBrightnessLevel." + (uuid.map { CFUUIDCreateString(nil, $0) as String } ?? String(id))
    }
  }

  private let discoveryQueue = DispatchQueue(label: "com.machinespirit.display-discovery")
  private(set) var displays: [Display] = []
  var onChange: (() -> Void)?
  private var observers: [NSObjectProtocol] = []
  private var wakeObservers: [NSObjectProtocol] = []
  private var discovered = false
  private var generation = 0
  private var screenSignature: [String] = []
  private var tap: CFMachPort?
  private var tapSource: CFRunLoopSource?
  private var huds: [CGDirectDisplayID: BrightnessHUD] = [:]
  private(set) var masterLevel =
    UserDefaults.standard.object(forKey: "msBrightnessLevel") as? Double ?? 100
  var keysAvailable: Bool { tap != nil }
  var sync: Bool {
    get { UserDefaults.standard.bool(forKey: "msBrightnessSync") }
    set {
      UserDefaults.standard.set(newValue, forKey: "msBrightnessSync")
      if newValue { setAll(masterLevel) }
      onChange?()
    }
  }
  var keysEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: "msBrightnessKeysEnabled") }
    set {
      UserDefaults.standard.set(newValue, forKey: "msBrightnessKeysEnabled")
      if let tap { CGEvent.tapEnable(tap: tap, enable: newValue) }
    }
  }

  func start() {
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.rebuild() })
    wakeObservers = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification].map {
      name in
      NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in self?.rebuild(force: true)
      }
    }
    if !NSRunningApplication.runningApplications(
      withBundleIdentifier: "app.monitorcontrol.MonitorControl"
    ).isEmpty {
      os_log(
        "Brightness: MonitorControl is running and may conflict with keys/gamma; quit it using System menu"
      )
    }
    rebuild(force: true)
    installTap()
  }

  func stop() {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    wakeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    observers.removeAll()
    wakeObservers.removeAll()
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
    tap = nil
    tapSource = nil
    generation += 1
    displays.removeAll()
    huds.values.forEach { $0.hide() }
    huds.removeAll()
    CGDisplayRestoreColorSyncSettings()
  }

  private func rebuild(force: Bool = false) {
    let screens = NSScreen.screens
    let signature = screens.map {
      "\($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? 0):\(NSStringFromRect($0.frame))"
    }
    guard force || signature != screenSignature else {
      reapplyGamma()
      return
    }
    screenSignature = signature
    discovered = false
    CGDisplayRestoreColorSyncSettings()
    generation += 1
    let version = generation
    displays = screens.map(Display.init)
    let snapshot = displays
    let ids = Set(snapshot.map { $0.id })
    for (id, hud) in huds where !ids.contains(id) {
      hud.hide()
      huds.removeValue(forKey: id)
    }
    onChange?()
    discoveryQueue.async {
      let services = DisplayHardware().services(for: snapshot.filter { !$0.builtIn }.map { $0.id })
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == version else { return }
        for display in snapshot { display.service = services[display.id] }
        self.discovered = true
        self.refresh()
      }
    }
  }

  func refresh() {
    guard discovered else { return }
    for display in displays where !display.reading && !display.writing && display.pending == nil {
      display.reading = true
      let revision = display.revision
      let version = generation
      let service = display.service
      display.queue.async {
        var percent: Double?
        var maximum: UInt16 = 100
        if display.builtIn {
          percent = display.hardware.readBuiltIn(display.id)
        } else if let service, let value = display.hardware.readDDC(service) {
          maximum = value.maximum
          percent = Double(value.current) / Double(maximum) * 100
          os_log(
            "Brightness DDC read: %{public}@ id=%u current=%u maximum=%u",
            display.screen.localizedName, display.id, value.current, value.maximum)
        }
        let result = percent
        let maxValue = maximum
        DispatchQueue.main.async { [weak self] in
          guard let self, version == self.generation else { return }
          display.reading = false
          let firstRead = !display.checked
          display.checked = true
          display.available = result != nil
          display.maximum = maxValue
          os_log(
            "Brightness: %{public}@ id=%u %{public}@ hardware=%.2f", display.screen.localizedName,
            display.id, display.available ? "hardware available" : "software only", result ?? -1)
          if firstRead {
            let saved = UserDefaults.standard.object(forKey: display.preferenceKey) as? Double
            let target =
              self.sync
              ? self.masterLevel
              : (revision != display.revision
                ? display.percent : saved ?? (result.map { 25 + 0.75 * $0 } ?? 100))
            self.set(display, percent: target)
          }
          self.onChange?()
        }
      }
    }
  }

  func setAll(_ percent: Double) {
    masterLevel = max(0, min(100, percent))
    UserDefaults.standard.set(masterLevel, forKey: "msBrightnessLevel")
    for display in displays { set(display, percent: masterLevel) }
  }

  func set(_ display: Display, percent: Double) {
    guard displays.contains(where: { $0 === display }) else { return }
    display.revision += 1
    display.percent = max(0, min(100, percent))
    UserDefaults.standard.set(display.percent, forKey: display.preferenceKey)
    // A pending level during discovery is applied once hardware support is known.
    guard display.checked else {
      onChange?()
      return
    }
    display.pending = display.percent
    onChange?()
    sendLatest(display)
  }

  private func sendLatest(_ display: Display) {
    guard !display.writing, let value = display.pending else { return }
    display.pending = nil
    display.writing = true
    let version = generation
    // Built-in backlights may switch off at literal zero; keep a 1% floor.
    let hardwareLevel = max(0, (value - 25) / 75 * 100)
    let service = display.service
    let available = display.available
    let rawValue = UInt16((hardwareLevel / 100 * Double(display.maximum)).rounded())
    // Gamma is immediate; a slow DDC port cannot delay another screen or the UI.
    setGamma(display, level: value)
    display.queue.async {
      let success =
        !available
        || (display.builtIn
          ? display.hardware.writeBuiltIn(display.id, percent: max(1, hardwareLevel))
          : service.map { display.hardware.writeDDC($0, value: rawValue) } ?? false)
      DispatchQueue.main.async { [weak self] in
        guard let self, version == self.generation else { return }
        display.writing = false
        if !success {
          display.available = false
          self.setGamma(display, level: display.percent)
          os_log(
            "Brightness write failed for %{public}@; using software dimming",
            display.screen.localizedName)
        }
        self.sendLatest(display)  // only the latest trailing value is retained
        self.onChange?()
      }
    }
  }

  private func setGamma(_ display: Display, level: Double) {
    let factor =
      display.available ? (level < 25 ? 0.15 + 0.85 * level / 25 : 1) : 0.15 + 0.85 * level / 100
    let wasDimmed = display.gamma < 1
    display.gamma = factor
    if factor == 1 && wasDimmed {
      // ColorSync restoration is global: immediately reapply every other dimmed screen.
      CGDisplayRestoreColorSyncSettings()
      reapplyGamma()
    } else if factor < 1 {
      applyGamma(display)
    }
  }

  private func applyGamma(_ display: Display) {
    let value = Float(display.gamma)
    let result = CGSetDisplayTransferByFormula(display.id, 0, value, 1, 0, value, 1, 0, value, 1)
    if result != .success {
      os_log("Brightness gamma failed display=%u error=%d", display.id, result.rawValue)
    }
  }

  private func reapplyGamma() {
    for display in displays where display.gamma < 1 { applyGamma(display) }
  }

  func installTap() {
    guard tap == nil else { return }
    tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap,
      options: .defaultTap, eventsOfInterest: 1 << 14,
      callback: { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<BrightnessController>.fromOpaque(context).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
          if let tap = owner.tap, owner.keysEnabled { CGEvent.tapEnable(tap: tap, enable: true) }
          return Unmanaged.passUnretained(event)
        }
        return owner.handleMediaKey(event) ? nil : Unmanaged.passUnretained(event)
      }, userInfo: Unmanaged.passUnretained(self).toOpaque())
    guard let tap else {
      os_log("Brightness keys unavailable (needs Accessibility)")
      return
    }
    os_log("Brightness key event tap installed")
    tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: keysEnabled)
  }

  private func handleMediaKey(_ event: CGEvent) -> Bool {
    guard keysEnabled, let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined,
      nsEvent.subtype.rawValue == 8
    else { return false }
    let key = (nsEvent.data1 >> 16) & 0xFFFF
    let state = (nsEvent.data1 >> 8) & 0xFF
    guard key == 2 || key == 3, state == 0xA || state == 0xB else { return false }
    let delta = key == 2 ? 6.25 : -6.25
    if sync {
      guard !displays.isEmpty else { return false }
      if state == 0xA {
        setAll(masterLevel + delta)
        showHUDs()
      }
      return true
    }
    guard let display = displays.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }),
      !display.builtIn
    else { return false }
    if state == 0xA {
      set(display, percent: display.percent + delta)
      showHUDs()
    }
    return true
  }

  private func showHUDs() {
    for display in displays {
      let hud = huds[display.id] ?? BrightnessHUD()
      huds[display.id] = hud
      hud.show(percent: display.percent, on: display.screen)
    }
  }
}
/// One reusable, non-activating panel per screen; only a one-shot dismissal is scheduled.
private final class BrightnessHUD {
  private let panel: NSPanel
  private let bar = NSLevelIndicator()
  private var dismissal: DispatchWorkItem?
  private var generation = 0

  init() {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 180, height: 40),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    let background = NSVisualEffectView(frame: panel.contentView!.bounds)
    background.material = .hudWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 10
    panel.contentView = background
    bar.frame = NSRect(x: 15, y: 14, width: 150, height: 12)
    bar.levelIndicatorStyle = .continuousCapacity
    bar.minValue = 0
    bar.maxValue = 100
    bar.warningValue = 101
    bar.criticalValue = 101
    background.addSubview(bar)
  }

  func show(percent: Double, on screen: NSScreen) {
    dismissal?.cancel()
    generation += 1
    let version = generation
    panel.setFrameOrigin(
      NSPoint(x: screen.visibleFrame.midX - 90, y: screen.visibleFrame.minY + 60))
    bar.doubleValue = percent
    panel.alphaValue = 1
    panel.orderFrontRegardless()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.generation == version else { return }
      NSAnimationContext.runAnimationGroup(
        { context in
          context.duration = 0.15
          self.panel.animator().alphaValue = 0
        },
        completionHandler: { [weak self] in
          guard let self, self.generation == version else { return }
          self.panel.orderOut(nil)
        })
    }
    dismissal = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
  }

  func hide() {
    generation += 1
    dismissal?.cancel()
    panel.orderOut(nil)
  }
}
