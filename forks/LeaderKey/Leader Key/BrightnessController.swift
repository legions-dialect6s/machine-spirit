import Cocoa
import os.log

/// UI state lives on main; every registry/brightness operation runs on one queue.
final class BrightnessController {
  final class Display {
    let id: CGDirectDisplayID
    let screen: NSScreen
    let builtIn: Bool
    var service: CFTypeRef?
    var percent: Double = 50
    var maximum: UInt16 = 100
    var available = false
    var checked = false
    var revision = 0
    var reading = false
    var writing = false
    var pending: Double?

    init(screen: NSScreen) {
      self.screen = screen
      id =
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint32Value ?? 0
      builtIn = CGDisplayIsBuiltin(id) != 0
    }
  }

  private let queue = DispatchQueue(
    label: "com.machinespirit.display-hardware", qos: .userInitiated)
  private let hardware = DisplayHardware()
  private(set) var displays: [Display] = []
  var onChange: (() -> Void)?
  private var observer: NSObjectProtocol?
  private var wakeObservers: [NSObjectProtocol] = []
  private var generation = 0
  private var discovered = false
  private var screenSignature: [String] = []
  private var tap: CFMachPort?
  private var tapSource: CFRunLoopSource?
  private let hud = BrightnessHUD()
  var keysAvailable: Bool { tap != nil }
  var keysEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: "msBrightnessKeysEnabled") }
    set {
      UserDefaults.standard.set(newValue, forKey: "msBrightnessKeysEnabled")
      if let tap { CGEvent.tapEnable(tap: tap, enable: newValue) }
    }
  }

  func start() {
    observer = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.rebuild() }
    wakeObservers = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification].map {
      name in
      NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in self?.rebuild(force: true)
      }
    }
    rebuild(force: true)
    installTap()
  }

  func stop() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    for observer in wakeObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    wakeObservers.removeAll()
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
    tap = nil
    tapSource = nil
    generation += 1
    displays = []
    screenSignature = []
    hud.hide()
  }

  private func rebuild(force: Bool = false) {
    let screens = NSScreen.screens
    let signature = screens.map { screen in
      "\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? 0):"
        + "\(NSStringFromRect(screen.frame)):\(screen.backingScaleFactor):\(screen.localizedName)"
    }
    // macOS also broadcasts screen-parameter changes without a topology change.
    // Preserve the cache and avoid re-probing DDC for those duplicate events.
    guard force || signature != screenSignature else { return }
    screenSignature = signature
    generation += 1
    discovered = false
    let version = generation
    displays = screens.map(Display.init)
    let snapshot = displays
    onChange?()
    let ids = snapshot.filter { !$0.builtIn }.map { $0.id }
    queue.async { [weak self] in
      guard let self else { return }
      let services = self.hardware.services(for: ids)
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
      queue.async { [weak self] in
        guard let self else { return }
        var percent: Double?
        var maximum: UInt16 = 100
        if display.builtIn {
          percent = self.hardware.readBuiltIn(display.id)
        } else if let service, let value = self.hardware.readDDC(service) {
          maximum = value.maximum
          percent = Double(value.current) / Double(maximum) * 100
        }
        let result = percent
        let maxValue = maximum
        DispatchQueue.main.async { [weak self] in
          guard let self, version == self.generation else { return }
          display.reading = false
          guard revision == display.revision else { return }  // a drag superseded this read
          display.checked = true
          display.available = result != nil
          if let result {
            display.percent = result
            display.maximum = maxValue
          }
          os_log(
            "System menu: display %{public}@ id=%u %{public}@ brightness=%.2f",
            display.screen.localizedName, display.id,
            display.builtIn
              ? (display.available ? "DisplayServices OK" : "DisplayServices unavailable")
              : (display.available ? "DDC answered" : "no DDC"), display.percent)
          self.onChange?()
        }
      }
    }
  }

  func set(_ display: Display, percent: Double) {
    guard displays.contains(where: { $0 === display }), display.available else { return }
    display.revision += 1
    display.percent = max(0, min(100, percent))
    display.pending = display.percent
    onChange?()
    sendLatest(display)
  }

  private func sendLatest(_ display: Display) {
    guard !display.writing, let value = display.pending else { return }
    display.pending = nil
    display.writing = true
    let version = generation
    let service = display.service
    let rawValue = UInt16((value / 100 * Double(display.maximum)).rounded())
    queue.async { [weak self] in
      guard let self else { return }
      let success: Bool
      if display.builtIn {
        success = self.hardware.writeBuiltIn(display.id, percent: value)
      } else if let service {
        success = self.hardware.writeDDC(service, value: rawValue)
      } else {
        success = false
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, version == self.generation else { return }
        display.writing = false
        if success {
          self.sendLatest(display)  // one trailing value, never a queue of stale slider positions
        } else {
          display.available = false
          display.pending = nil
          os_log(
            "System menu: brightness write failed for %{public}@", display.screen.localizedName)
          self.onChange?()
        }
      }
    }
  }

  func installTap() {
    guard tap == nil else { return }
    let mask: CGEventMask = 1 << 14  // NX_SYSDEFINED; CGEventType has no named case
    tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap,
      options: .defaultTap, eventsOfInterest: mask,
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
      os_log("System menu: brightness keys unavailable (needs Accessibility)")
      return
    }
    os_log("System menu: brightness key event tap installed")
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
    guard key == 2 || key == 3, state == 0xA || state == 0xB,
      let display = displays.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }),
      !display.builtIn, display.available
    else { return false }
    if state == 0xA {
      set(display, percent: display.percent + (key == 2 ? 6.25 : -6.25))
      hud.show(percent: display.percent, on: display.screen)
    }
    return true
  }
}

/// A single reusable, non-activating panel; only a one-shot dismissal is scheduled.
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
