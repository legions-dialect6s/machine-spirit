import AppKit
import QuartzCore

/// Coordinates stay in AppKit here. This is mouseZone + placementFrame from
/// tools/ms/Sources/ms/WindowGeometry.swift with the AX y reflection applied.
struct SmartPlacement: Equatable {
  let frame: CGRect
  let label: String
  static func target(mouse: CGPoint, visibleFrame s: CGRect) -> Self {
    guard s.width > 0, s.height > 0 else { return Self(frame: s, label: "almost maximize") }
    let u = min(1, max(0, (mouse.x - s.minX) / s.width))
    let v = min(1, max(0, (s.maxY - mouse.y) / s.height))
    let left = u < 0.10, right = u > 0.90, top = v < 0.10, bottom = v > 0.90
    if (left || right) && (top || bottom) {
      return Self(frame: CGRect(x: right ? s.midX : s.minX, y: top ? s.midY : s.minY,
        width: s.width / 2, height: s.height / 2),
        label: "\(top ? "top" : "bottom")-\(left ? "left" : "right") quarter")
    }
    if left || right {
      return Self(frame: CGRect(x: right ? s.midX : s.minX, y: s.minY, width: s.width / 2, height: s.height),
                  label: left ? "left half" : "right half")
    }
    if top || bottom {
      return Self(frame: CGRect(x: s.minX, y: top ? s.midY : s.minY, width: s.width, height: s.height / 2),
                  label: top ? "top half" : "bottom half")
    }
    return Self(frame: s.insetBy(dx: s.width * 0.05, dy: s.height * 0.05), label: "almost maximize")
  }
}

final class OverlaySurfacePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  init() {
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isOpaque = false; backgroundColor = .clear; hasShadow = false
    ignoresMouseEvents = true; isReleasedWhenClosed = false; hidesOnDeactivate = false
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
  }
}

@MainActor
final class PlacementPreview {
  private(set) var panel: OverlaySurfacePanel?
  private let outline = CALayer()
  private let label = CATextLayer()
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var displayObserver: NSObjectProtocol?
  private(set) var active = false
  private(set) var target: SmartPlacement?
  private var fx = OverlayFX()
  private var armedPath: String?
  private var committed = false
  private var intent: PlacementIntent?
  private var window: ObservedWindow?
  private var owner: pid_t?
  private var observation: Task<Void, Never>?
  private var activationObserver: NSObjectProtocol?
  private let currentOwner: () -> pid_t?
  private let query: @Sendable (pid_t, CGWindowID?) async -> ObservedWindow?

  init(currentOwner: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
       query: @escaping @Sendable (pid_t, CGWindowID?) async -> ObservedWindow? = ObservedWindow.read) {
    self.currentOwner = currentOwner
    self.query = query
  }
  var monitoring: Bool { globalMonitor != nil || localMonitor != nil }

  func arm(_ next: PlacementIntent, path: String, fx: OverlayFX) {
    guard fx.placementPreview else { hide(); return }
    if armedPath == path && !committed { return }
    hide()
    intent = next
    armedPath = path
    self.fx = fx
    active = true
    if next == .mouse { showMouse() }
    guard let pid = currentOwner() else { return }
    owner = pid
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        if let self, self.currentOwner() != self.owner { self.hide() }
      }
    }
    observation = Task { [weak self, query] in
      let source = await query(pid, nil)
      guard let self, !Task.isCancelled, armedPath == path, !committed, currentOwner() == pid else { return }
      window = source
      guard let source, let (placement, screen) = next.destination(window: source.frame, screens: NSScreen.screens) else { return }
      render(placement, on: screen)
    }
  }

  /// A fired bind is posted before the launcher runs the command. The board alone
  /// watches for its landing. No monitor or animation lies on the launcher's key path.
  func fire(path: String) {
    guard armedPath == path, active, !committed, let owner, currentOwner() == owner,
          let window, let intent, let primary = NSScreen.screens.first else { hide(); return }
    if intent == .mouse { update(mouse: NSEvent.mouseLocation) }
    guard let target, let display = panel?.screen else { hide(); return }
    committed = true
    active = false
    stopTrackingMouse()
    let expected = flipScreenRect(target.frame, primaryTop: primary.frame.maxY)
    let screens = NSScreen.screens
    let frames = screens.map { flipScreenRect($0.frame, primaryTop: primary.frame.maxY) }
    let displayIndex = screens.firstIndex(of: display)
    observation?.cancel()
    observation = Task { [weak self, query] in
      let deadline = ContinuousClock.now + .milliseconds(700)
      repeat {
        // The first sample follows command dispatch. This task suspends off the launcher queue.
        try? await Task.sleep(for: .milliseconds(25))
        guard !Task.isCancelled else { return }
        let current = await query(owner, window.id)
        guard let self, !Task.isCancelled else { return }
        guard let current, currentOwner() == owner else { hide(); return }
        let landed: Bool
        if case .cycle = intent { landed = overlapScreen(current.frame, screens: frames) == displayIndex }
        else { landed = ObservedWindow.matches(current.frame, expected) }
        if landed {
          let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.13
          if duration > 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = Float(1); fade.toValue = Float(0); fade.duration = duration
            CATransaction.begin(); CATransaction.setDisableActions(true)
            outline.opacity = 0; outline.add(fade, forKey: "landing")
            CATransaction.commit()
            try? await Task.sleep(for: .seconds(duration))
          }
          if !Task.isCancelled { hide() }
          return
        }
      } while ContinuousClock.now < deadline
      if !Task.isCancelled { self?.hide() }
    }
  }

  func leaveNavigation() {
    if !committed { hide() }
  }

  @discardableResult func preparePanel() -> OverlaySurfacePanel {
    if panel == nil {
      let panel = OverlaySurfacePanel()
      let view = NSView(); view.wantsLayer = true
      panel.contentView = view
      outline.cornerRadius = 12; outline.borderWidth = 2
      outline.shadowRadius = 10; outline.shadowOffset = .zero
      label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
      label.fontSize = 13; label.alignmentMode = .center
      label.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 0.94).cgColor
      label.cornerRadius = 7
      view.layer?.addSublayer(outline); outline.addSublayer(label)
      self.panel = panel
    }
    return panel!
  }

  private func showMouse() {
    update(mouse: NSEvent.mouseLocation)
    guard !monitoring else { return }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
      MainActor.assumeIsolated { self?.update(mouse: NSEvent.mouseLocation) }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
      self?.update(mouse: NSEvent.mouseLocation); return event
    }
    displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.update(mouse: NSEvent.mouseLocation) }
    }
  }

  func update(mouse: CGPoint) {
    guard active, intent == .mouse, let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return }
    render(SmartPlacement.target(mouse: mouse, visibleFrame: screen.visibleFrame), on: screen)
  }

  private func render(_ next: SmartPlacement, on screen: NSScreen) {
    let panel = preparePanel()
    let movedScreen = panel.frame != screen.frame
    guard next != target || movedScreen else { return }
    let previous = outline.presentation()?.frame ?? outline.frame
    let hadTarget = target != nil
    target = next
    CATransaction.begin(); CATransaction.setDisableActions(true)
    panel.setFrame(screen.frame, display: false)
    outline.opacity = 1
    outline.contentsScale = screen.backingScaleFactor; label.contentsScale = screen.backingScaleFactor
    let color = fx.accentColor.cgColor
    outline.borderColor = color; outline.shadowColor = color
    outline.shadowOpacity = fx.skullGlow ? 0.5 : 0
    outline.backgroundColor = color.copy(alpha: 0.035)
    outline.frame = next.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    // Glow follows only the stroke; a filled shadow path would turn the
    // otherwise 3.5%-alpha interior into a bright green sheet.
    outline.shadowPath = CGPath(roundedRect: outline.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
      .copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
    label.foregroundColor = color; label.string = next.label
    label.frame = CGRect(x: max(4, (outline.bounds.width - 220) / 2), y: outline.bounds.height - 40,
                         width: min(220, outline.bounds.width - 8), height: 26)
    if hadTarget && !movedScreen && fx.openingDuration > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      for (key, from, to) in [("position", NSValue(point: CGPoint(x: previous.midX, y: previous.midY)), NSValue(point: outline.position)),
                             ("bounds", NSValue(rect: CGRect(origin: .zero, size: previous.size)), NSValue(rect: outline.bounds))] {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from; animation.toValue = to; animation.duration = 0.15
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        outline.add(animation, forKey: key)
      }
    } else { outline.removeAllAnimations() }
    CATransaction.commit()
    panel.orderFrontRegardless()
  }

  func hide() {
    guard armedPath != nil || active || committed else { return }
    observation?.cancel(); observation = nil
    if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    activationObserver = nil
    active = false; target = nil; armedPath = nil; committed = false
    owner = nil; intent = nil; window = nil
    stopTrackingMouse()
    outline.removeAllAnimations(); panel?.orderOut(nil)
  }

  private func stopTrackingMouse() {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
    globalMonitor = nil; localMonitor = nil; displayObserver = nil
  }
}

/// Shared display typography and composited glass, with no bundled font dependency.
enum OverlaySurfaceStyle {
  static func displayFont(size: CGFloat) -> NSFont {
    NSFont(name: "DINCondensed-Bold", size: size)
      ?? NSFont(name: "AvenirNextCondensed-DemiBold", size: size)
      ?? NSFontManager.shared.convert(NSFont.systemFont(ofSize: size, weight: .bold), toHaveTrait: .condensedFontMask)
  }

  static func glass(accent: NSColor) -> CGColor {
    let rgb = accent.usingColorSpace(.sRGB)!
    // 15% accent over 55% near-black; preserve the resulting 61.75% alpha.
    let alpha: CGFloat = 0.15 + 0.55 * 0.85
    func channel(_ value: CGFloat) -> CGFloat { (value * 0.15 + 0.02 * 0.55 * 0.85) / alpha }
    return NSColor(srgbRed: channel(rgb.redComponent), green: channel(rgb.greenComponent),
                   blue: channel(rgb.blueComponent), alpha: alpha).cgColor
  }

  static func displayText(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
    NSAttributedString(string: text.uppercased(), attributes: [
      .font: displayFont(size: size), .kern: 0.8, .foregroundColor: color])
  }
}

@MainActor
final class OverlayHUD {
  private(set) var panels: [OverlaySurfacePanel] = []
  private var dismissal: DispatchSourceTimer?
  private var revision = 0
  private var currentStyle: String?
  private var isDismissing = false

  func show(url: URL, fx: OverlayFX = OverlayFX()) {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    let style = value("style")
    guard fx.hud, style == "caps" || style == "text" else { return }
    if style == "caps", value("state") != "on", value("state") != "off" { return }
    let caps = style == "caps", on = value("state") == "on"
    let color = caps && on ? OverlayFX.color(hex: "#FF5A3C")! : fx.accentColor
    let title = caps ? (on ? "CAPS ON" : "CAPS OFF") : String((value("title") ?? "").prefix(512))
    let body = String((value("text") ?? "").prefix(16_384))
    guard caps || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let mouse = NSEvent.mouseLocation
    let screens = caps ? NSScreen.screens : [NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main].compactMap { $0 }
    let reuse = caps && currentStyle == "caps" && panels.count == screens.count
      && zip(panels, screens).allSatisfy { $0.screen === $1 }
    let resume = reuse && isDismissing
    if !reuse { dismiss(animated: false) }
    revision += 1; dismissal?.cancel(); dismissal = nil
    isDismissing = false; currentStyle = style
    CATransaction.begin(); CATransaction.setDisableActions(true)
    for (index, screen) in screens.enumerated() {
      let safe = screen.visibleFrame
      // The visible pill is 240 x 40, inset by 10 for glow and the 8pt slide.
      let width = max(80, min(caps ? 260 : 420, safe.width - 24))
      let titleText = OverlaySurfaceStyle.displayText(title, size: caps ? 21 : 19, color: color)
      let bodyText = NSAttributedString(string: body, attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(white: 0.95, alpha: 1)])
      let textWidth = width - 52
      let titleHeight = title.isEmpty ? 0 : min(max(24, (safe.height - 100) / 3),
        ceil(titleText.boundingRect(with: CGSize(width: textWidth, height: 1000),
          options: [.usesLineFragmentOrigin, .usesFontLeading]).height))
      let textHeight = ceil(bodyText.boundingRect(with: CGSize(width: textWidth, height: 10_000),
        options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
      let gap: CGFloat = title.isEmpty || body.isEmpty ? 0 : 10
      let height = caps ? 60 : min(safe.height - 24, max(64, titleHeight + textHeight + gap + 48))
      let origin = caps ? CGPoint(x: safe.midX - width / 2, y: safe.maxY - height)
        : CGPoint(x: min(max(mouse.x + 18, safe.minX + 12), safe.maxX - width - 12),
                  y: min(max(mouse.y - height - 18, safe.minY + 12), safe.maxY - height - 12))
      let panel = reuse ? panels[index] : OverlaySurfacePanel()
      panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: false)
      let view = reuse ? panel.contentView as! HUDCardView : HUDCardView(frame: CGRect(origin: .zero, size: panel.frame.size))
      let card = view.card
      // Do not set frame while a fading card has a translation transform:
      // CALayer would compensate its position and shift the resumed pill down.
      card.bounds = CGRect(origin: .zero, size: view.bounds.insetBy(dx: 10, dy: 10).size)
      card.position = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
      card.backgroundColor = OverlaySurfaceStyle.glass(accent: fx.accentColor)
      card.cornerRadius = caps ? 20 : 14
      card.borderColor = color.withAlphaComponent(0.9).cgColor; card.borderWidth = 1.25
      card.shadowColor = fx.accentColor.cgColor; card.shadowRadius = 6
      card.shadowOpacity = fx.skullGlow ? 0.35 : 0; card.shadowOffset = .zero
      card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: card.cornerRadius,
        cornerHeight: card.cornerRadius, transform: nil)
        .copy(strokingWithWidth: 1.25, lineCap: .round, lineJoin: .round, miterLimit: 1)
      card.contentsScale = screen.backingScaleFactor
      card.sublayers = nil
      func text(_ string: NSAttributedString, frame: CGRect) {
        let layer = CATextLayer(); layer.frame = frame; layer.string = string
        layer.contentsScale = screen.backingScaleFactor
        layer.isWrapped = true; layer.truncationMode = .end
        card.addSublayer(layer)
      }
      if caps {
        let glyph = NSAttributedString(string: "⇪", attributes: [
          .font: NSFont.systemFont(ofSize: 17, weight: .regular), .foregroundColor: color])
        let titleWidth = ceil(titleText.size().width)
        let left = (card.bounds.width - titleWidth - 27) / 2
        text(glyph, frame: CGRect(x: left, y: 9, width: 20, height: 24))
        text(titleText, frame: CGRect(x: left + 27, y: 9, width: titleWidth + 2, height: 27))
      } else {
        text(titleText, frame: CGRect(x: 16, y: 14, width: textWidth, height: titleHeight))
        text(bodyText, frame: CGRect(x: 16, y: 14 + titleHeight + gap, width: textWidth,
          height: max(0, card.bounds.height - titleHeight - gap - 28)))
      }
      if !reuse { panel.contentView = view; panels.append(panel) }
      panel.ignoresMouseEvents = caps
      view.dismiss = { [weak self] in self?.dismiss(animated: fx.close && fx.closeDuration > 0) }
      if !reuse || resume {
        transition(card, visible: true, duration: fx.openingDuration > 0 ? 0.16 : 0, fresh: !reuse)
      }
      panel.orderFrontRegardless()
    }
    CATransaction.commit()
    let token = revision
    // One expiry wakeup; every animated frame belongs to Core Animation.
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
    let entrance = (!reuse || resume) && fx.openingDuration > 0 ? 0.16 : 0
    timer.schedule(deadline: .now() + (caps ? entrance + 1.1 : 10), leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.revision == token else { return }
        self.dismiss(animated: fx.close && fx.closeDuration > 0)
      }
    }
    dismissal = timer; timer.resume()
  }

  private func transition(_ card: CALayer, visible: Bool, duration: Double, fresh: Bool = false) {
    for (key, end) in [("opacity", visible ? 1.0 : 0.0),
                       ("transform.translation.y", visible ? 0.0 : -8.0)] {
      let start: Any = fresh ? (key == "opacity" ? 0.0 : -8.0)
        : (card.presentation()?.value(forKeyPath: key) ?? card.value(forKeyPath: key)!)
      card.removeAnimation(forKey: key); card.setValue(end, forKeyPath: key)
      if duration > 0 {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = start; animation.toValue = end; animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        card.add(animation, forKey: key)
      }
    }
  }

  func dismiss(animated: Bool = true) {
    revision += 1; dismissal?.cancel(); dismissal = nil
    let token = revision
    guard animated, !panels.isEmpty else {
      panels.forEach { $0.orderOut(nil) }; panels = []; currentStyle = nil; isDismissing = false
      return
    }
    isDismissing = true
    CATransaction.begin(); CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.revision == token else { return }
        self.panels.forEach { $0.orderOut(nil) }
        self.panels = []; self.currentStyle = nil; self.isDismissing = false
      }
    }
    for panel in panels {
      if let view = panel.contentView as? HUDCardView { transition(view.card, visible: false, duration: 0.22) }
    }
    CATransaction.commit(); CATransaction.flush()
  }
}

private final class HUDCardView: NSView {
  let card = CALayer()
  var dismiss: (() -> Void)?
  override init(frame: NSRect) {
    super.init(frame: frame)
    let root = CALayer(); root.isGeometryFlipped = true
    layer = root; wantsLayer = true; layerContentsRedrawPolicy = .never
    root.addSublayer(card)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { dismiss?() }
}
