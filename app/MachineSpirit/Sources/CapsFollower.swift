import AppKit
import OSLog
import QuartzCore

/// The flags listeners are dormant between events. Only ON owns mouse monitors
/// and a window; all movement is one direct frame update per delivered event.
@MainActor
final class CapsFollower {
  private(set) var panel: OverlaySurfacePanel?
  private(set) var capsOn = false
  private var globalFlags: Any?
  private var localFlags: Any?
  private var globalMouse: Any?
  private var localMouse: Any?
  private var preferencesObserver: NSObjectProtocol?
  private let defaults: UserDefaults
  private let readFlags: () -> CGEventFlags
  private var fx: OverlayFX
  private var revision = 0
  private var fading = false
  var mouseMonitorCount: Int { [globalMouse, localMouse].compactMap { $0 }.count }
  var flagsMonitorCount: Int { [globalFlags, localFlags].compactMap { $0 }.count }

  init(defaults: UserDefaults = .standard,
       readFlags: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) }) {
    self.defaults = defaults; self.readFlags = readFlags
    fx = OverlayFX(defaults: defaults)
  }

  func start() {
    guard preferencesObserver == nil else { return }
    globalFlags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated { self?.flagsChanged(event) }
    }
    // Global monitors exclude our own app (for example, when the board is key).
    localFlags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated { self?.flagsChanged(event) }
      return event
    }
    preferencesObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.preferencesChanged() }
    }
    capsOn = readFlags().contains(.maskAlphaShift)
    reconcile()
  }

  func receiveHUD(url: URL) {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
    if value("style") == "caps", let state = value("state"), state == "on" || state == "off" {
      capsOn = state == "on"
    }
    // A queued URL can be stale after another toggle. Reconcile with hardware
    // on EVERY HUD URL (including text); never schedule a poll or retry.
    capsOn = readFlags().contains(.maskAlphaShift)
    fx = OverlayFX(defaults: defaults)
    reconcile()
  }

  private static let log = Logger(subsystem: "com.machinespirit.app", category: "caps")

  private func flagsChanged(_ event: NSEvent? = nil) {
    // Read current HID state at event delivery, rather than trusting modifier
    // bits in a queued or synthetic event. This is event-driven, never polling.
    let on = readFlags().contains(.maskAlphaShift)
    guard capsOn != on else { return }
    capsOn = on
    // Diagnostic for a badge that lights with Caps Lock off: name the event's sender
    // (0 = hardware). Read with `log show --predicate 'category == "caps"'`.
    if let cg = event?.cgEvent {
      let pid = cg.getIntegerValueField(.eventSourceUnixProcessID)
      let sender = pid == 0 ? "hardware"
        : NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName ?? "pid \(pid)"
      Self.log.notice(
        "badge \(on ? "on" : "off", privacy: .public): key=\(cg.getIntegerValueField(.keyboardEventKeycode)) event-flags=0x\(String(cg.flags.rawValue, radix: 16), privacy: .public) sender=\(sender, privacy: .public)")
    }
    reconcile()
  }

  private func preferencesChanged() {
    let next = OverlayFX(defaults: defaults)
    guard next.capsFollower != fx.capsFollower || next.accentHex != fx.accentHex
      || next.skullGlow != fx.skullGlow else { return }
    fx = next
    reconcile()
  }

  private func reconcile() {
    guard capsOn && fx.capsFollower else { hide(); return }
    revision += 1; fading = false
    if panel == nil {
      let window = OverlaySurfacePanel()
      window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
      window.setContentSize(CGSize(width: 36, height: 26))
      window.contentView = CapsBadgeView(frame: CGRect(x: 0, y: 0, width: 36, height: 26))
      panel = window
      lastMove = 0
      lastScale = 0
    }
    guard let panel, let view = panel.contentView as? CapsBadgeView else { return }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    view.layer?.removeAllAnimations(); view.layer?.opacity = 1
    view.style(fx: fx)
    CATransaction.commit()
    move(to: NSEvent.mouseLocation)
    panel.orderFrontRegardless()
    guard mouseMonitorCount == 0 else { return }
    let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
    globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
      MainActor.assumeIsolated { self?.move(to: NSEvent.mouseLocation) }
    }
    localMouse = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      MainActor.assumeIsolated { self?.move(to: NSEvent.mouseLocation) }
      return event
    }
  }

  /// AppKit coordinates are bottom-up. Offset refers to the visible badge's
  /// top-left; the extra 4pt on each side gives its glass glow room to breathe.
  static func origin(mouse: CGPoint, screen: CGRect) -> CGPoint {
    var x = mouse.x + 14 - 4
    var y = mouse.y - 18 - 18 - 4
    if x + 36 > screen.maxX { x = mouse.x - 14 - 28 - 4 }
    if y < screen.minY { y = mouse.y + 18 - 4 }
    return CGPoint(x: min(max(x, screen.minX), screen.maxX - 36),
                   y: min(max(y, screen.minY), screen.maxY - 26))
  }

  private var lastMove: CFTimeInterval = 0
  private var lastScale: CGFloat = 0
  private var pendingMouse: CGPoint?
  private var trailingMove: Task<Void, Never>?

  func move(to mouse: CGPoint) {
    // ≤ 60 window moves/s (120 Hz pointers otherwise double the WindowServer work).
    guard capsOn, fx.capsFollower, !fading, let panel else { return }
    let now = CACurrentMediaTime()
    let remaining = 1.0 / 60 - (now - lastMove)
    if remaining > 0 {
      pendingMouse = mouse
      if trailingMove == nil {
        trailingMove = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
          guard let self else { return }
          trailingMove = nil
          if let point = pendingMouse { move(to: point) }
        }
      }
      return
    }
    pendingMouse = nil
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
    lastMove = now
    panel.setFrameOrigin(Self.origin(mouse: mouse, screen: screen.frame))
    if screen.backingScaleFactor != lastScale {
      lastScale = screen.backingScaleFactor
      (panel.contentView as? CapsBadgeView)?.setScale(lastScale)
    }
  }

  private func removeMouseMonitors() {
    trailingMove?.cancel()
    trailingMove = nil
    pendingMouse = nil
    if let globalMouse { NSEvent.removeMonitor(globalMouse) }
    if let localMouse { NSEvent.removeMonitor(localMouse) }
    globalMouse = nil; localMouse = nil
  }

  private func hide() {
    removeMouseMonitors()
    guard let panel, !fading, let layer = panel.contentView?.layer else { return }
    fading = true; revision += 1
    let token = revision
    CATransaction.begin(); CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.revision == token else { return }
        self.panel?.close(); self.panel = nil; self.fading = false
      }
    }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
    fade.toValue = 0; fade.duration = 0.15
    layer.opacity = 0; layer.add(fade, forKey: "capsFade")
    CATransaction.commit(); CATransaction.flush()
  }

  func stop() {
    revision += 1
    removeMouseMonitors()
    if let globalFlags { NSEvent.removeMonitor(globalFlags) }
    if let localFlags { NSEvent.removeMonitor(localFlags) }
    globalFlags = nil; localFlags = nil
    if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    preferencesObserver = nil
    panel?.contentView?.layer?.removeAllAnimations()
    panel?.close(); panel = nil; fading = false; capsOn = false
  }
}

private final class CapsBadgeView: NSView {
  private let card = CALayer()
  private let glyph = CATextLayer()
  override init(frame: NSRect) {
    super.init(frame: frame)
    let root = CALayer(); root.isGeometryFlipped = true
    layer = root; wantsLayer = true; layerContentsRedrawPolicy = .never
    card.frame = CGRect(x: 4, y: 4, width: 28, height: 18)
    card.cornerRadius = 9; card.borderWidth = 1
    card.shadowRadius = 3; card.shadowOffset = .zero
    card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: 9, cornerHeight: 9, transform: nil)
    glyph.frame = CGRect(x: 0, y: 0, width: 28, height: 18)
    glyph.alignmentMode = .center
    glyph.string = NSAttributedString(string: "⇪", attributes: [
      .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
      .foregroundColor: OverlayFX.color(hex: "#FF5A3C")!])
    card.addSublayer(glyph); root.addSublayer(card)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
  override var isFlipped: Bool { true }
  func style(fx: OverlayFX) {
    card.backgroundColor = OverlaySurfaceStyle.glass(accent: fx.accentColor)
    card.borderColor = OverlayFX.color(hex: "#FF5A3C")!.withAlphaComponent(0.9).cgColor
    card.shadowColor = fx.accentColor.cgColor; card.shadowOpacity = fx.skullGlow ? 0.35 : 0
  }
  func setScale(_ scale: CGFloat) {
    guard glyph.contentsScale != scale else { return }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layer?.contentsScale = scale; card.contentsScale = scale; glyph.contentsScale = scale
    CATransaction.commit()
  }
}
