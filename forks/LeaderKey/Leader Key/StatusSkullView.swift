import Cocoa
import QuartzCore

/// Compositor-only feedback over the compact bar's reserved icon slot.
final class StatusSkullView: NSView {
  private let slot = CALayer()
  private let animationSources = CALayer()
  private var displayedLayers: [CAShapeLayer] = []
  private let skull = CAShapeLayer()
  private let ring = CAShapeLayer()
  private let ghosts = [CAShapeLayer(), CAShapeLayer()]
  private var sourceLayers: [CAShapeLayer] { [ring] + ghosts + [skull] }
  private let defaults: UserDefaults
  private let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
  private let red = NSColor(srgbRed: 1, green: 59 / 255, blue: 59 / 255, alpha: 1).cgColor
  private let blue = NSColor(srgbRed: 59 / 255, green: 168 / 255, blue: 1, alpha: 1).cgColor
  private var fx = OverlayFX()
  private var active = false
  private var dark = false
  private var previousPath = ""
  private var snapshotTimer: Timer?
  private var snapshotDeadline: CFTimeInterval = 0
  private var newAnimationDuration: CFTimeInterval = 0
  private var tempo = OverlayTempo()
  private let reduceMotion: () -> Bool
  private var baseColor: CGColor { (active ? fx.accentColor : dark ? .white : .black).cgColor }
  override var isFlipped: Bool { true }

  init(button: NSStatusBarButton,
       defaults: UserDefaults = UserDefaults(suiteName: "com.machinespirit.MachineSpirit") ?? .standard,
       reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
    self.defaults = defaults
    self.reduceMotion = reduceMotion
    super.init(frame: button.bounds)
    let root = CALayer()
    root.isGeometryFlipped = true
    layer = root
    wantsLayer = true
    autoresizingMask = [.width, .height]
    slot.masksToBounds = true
    root.addSublayer(slot)
    // Mirrors snapshot layer models. Keep the CA timeline on invisible
    // sources and copy its presentation to the visible layers on demand.
    animationSources.opacity = 0
    slot.addSublayer(animationSources)
    ring.path = CGPath(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18), transform: nil)
    ring.fillColor = nil
    ring.lineWidth = 0.7
    ring.opacity = 0
    animationSources.addSublayer(ring)
    let path = SkullMark.path(in: CGRect(x: -7, y: -7, width: 14, height: 14))
    for (index, ghost) in ghosts.enumerated() {
      ghost.path = path
      ghost.fillRule = .evenOdd
      ghost.fillColor = (index == 0 ? NSColor.systemCyan : NSColor.systemPurple).cgColor
      ghost.opacity = 0
      animationSources.addSublayer(ghost)
    }
    skull.path = path
    skull.fillRule = .evenOdd
    skull.shadowOffset = .zero
    skull.shadowRadius = 2
    animationSources.addSublayer(skull)
    applyColor()
    displayedLayers = sourceLayers.map { source in
      let displayed = CAShapeLayer()
      displayed.path = source.path
      displayed.fillRule = source.fillRule
      displayed.lineWidth = source.lineWidth
      displayed.shadowOffset = source.shadowOffset
      slot.addSublayer(displayed)
      return displayed
    }
    syncDisplayedLayers(settled: true)
    button.addSubview(self)
    align()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    align()
  }

  func align() {
    guard let button = superview as? NSStatusBarButton, button.image != nil else { return }
    let image = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
    let frame = CGRect(x: image.minX, y: 0, width: CompactBar.skullWidth, height: bounds.height)
    guard slot.frame != frame else { return }
    withoutActions {
      slot.frame = frame
      let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
      for layer in sourceLayers + displayedLayers { layer.position = center }
    }
  }

  func configure(visible: Bool, dark: Bool, scale: CGFloat) {
    guard isHidden != !visible || self.dark != dark || skull.contentsScale != scale else { return }
    self.dark = dark
    withoutActions {
      isHidden = !visible
      for layer in sourceLayers + displayedLayers { layer.contentsScale = scale }
      if !visible {
        for layer in sourceLayers { layer.removeAllAnimations() }
        stopSnapshotRefresh()
      }
      applyColor()
      syncDisplayedLayers(settled: snapshotTimer == nil)
    }
  }

  func setActive(_ active: Bool) {
    guard active != self.active else { return }
    let previousColor = skull.presentation()?.fillColor ?? skull.fillColor
    self.active = active
    stopSnapshotRefresh()
    if active {
      fx = OverlayFX(defaults: defaults)
      tempo = OverlayTempo()
      _ = tempo.key(at: CACurrentMediaTime())
      previousPath = ""
    }
    withoutActions(refreshSnapshot: true) {
      for layer in sourceLayers { layer.removeAllAnimations() }
      applyColor()
      guard !isHidden, fx.skull else { return }
      let duration = active ? fx.openingDuration : (fx.close ? fx.closeDuration : 0)
      guard duration > 0 else { return }
      if let previousColor { colors(from: previousColor, duration: duration) }
      guard !reduceMotion() else { return }
      if active {
        animate(skull, key: "transform.scale", values: [0.55, 1.25, 1],
                duration: max(0.22, duration), times: [0, 0.58, 1])
        if fx.skullGlow {
          animate(skull, key: "shadowRadius", values: [5, 2], duration: max(0.22, duration))
        }
      } else {
        let tail = fx.glitch > 0 ? max(duration, 0.2) : duration
        animate(skull, key: "transform.scale", values: [1, 0.72, 1], duration: tail)
        if fx.glitch > 0 {
          for (index, ghost) in ghosts.enumerated() {
            animate(ghost, key: "transform.translation.x", values: [0, (index == 0 ? -2 : 2) * fx.glitch],
                    duration: tail)
            animate(ghost, key: "opacity", values: [0.6 * fx.glitch, 0], duration: tail)
          }
        }
      }
    }
  }

  func navigate(_ path: String) {
    guard active, !isHidden, fx.skull, path != previousPath else { return }
    previousPath = path
    let intensity = tempo.key(at: CACurrentMediaTime())
    guard !reduceMotion(), fx.openingDuration > 0 else { return }
    withoutActions(refreshSnapshot: true) {
      if fx.letterPop { pulse(1.08 + 0.15 * intensity, duration: fx.popDuration) }
      if fx.shockwave { shockwave() }
      if intensity > 0.5, fx.glitch > 0 {
        let offset = 1.8 * fx.glitch * intensity
        animate(skull, key: "transform.translation.x", values: [offset, -offset, offset / 3, 0], duration: 0.12)
      }
    }
  }

  func feedback(_ kind: String) {
    guard !isHidden, fx.skull else { return }
    withoutActions(refreshSnapshot: true) {
      switch kind {
      case "miss" where fx.miss:
        colors(from: red, duration: fx.missDuration)
        pulse(1.28, duration: fx.missDuration, twice: true)
      case "done" where fx.done:
        colors(from: blue, duration: fx.doneDuration)
        pulse(1.15, duration: fx.doneDuration)
      case "back" where fx.back:
        pulse(1.15, duration: fx.popDuration)
      case "hold" where fx.hold:
        pulse(1.12, duration: fx.holdDuration)
        if !reduceMotion(), fx.shockwave { shockwave() }
      default: break
      }
    }
  }

  func refreshMotionPolicy() {
    guard reduceMotion() else { return }
    for layer in sourceLayers { layer.removeAllAnimations() }
    stopSnapshotRefresh()
    refreshStatusSnapshot(settled: true)
  }

  private func applyColor() {
    skull.fillColor = baseColor
    skull.shadowColor = baseColor
    skull.shadowOpacity = active && fx.skullGlow ? 0.55 : 0
  }

  private func colors(from color: CGColor, duration: Double) {
    animate(skull, key: "fillColor", values: [color, color, baseColor], duration: duration, times: [0, 0.55, 1])
    animate(skull, key: "shadowColor", values: [color, color, baseColor], duration: duration, times: [0, 0.55, 1])
  }

  private func pulse(_ strength: Double, duration: Double, twice: Bool = false) {
    guard !reduceMotion() else { return }
    animate(skull, key: "transform.scale", values: twice ? [1, strength, 1, strength, 1] : [1, strength, 1],
            duration: duration)
  }

  private func shockwave() {
    ring.strokeColor = fx.accentColor.cgColor
    animate(ring, key: "transform.scale", values: [0.55, 1], duration: fx.shockwaveDuration)
    animate(ring, key: "opacity", values: [0.7, 0], duration: fx.shockwaveDuration)
  }

  private func animate(_ layer: CALayer, key: String, values: [Any], duration: Double, times: [NSNumber]? = nil) {
    guard duration > 0 else { return }
    newAnimationDuration = max(newAnimationDuration, duration)
    let animation = CAKeyframeAnimation(keyPath: key)
    animation.values = values
    animation.keyTimes = times
    animation.duration = duration
    animation.timingFunctions = Array(repeating: ease, count: values.count - 1)
    layer.add(animation, forKey: key)
  }

  /// macOS mirrors can reuse a status button snapshot while the actual
  /// sublayers animate. Ask AppKit for bounded compositor snapshots without
  /// replacing the metrics image or doing any idle work.
  private func syncDisplayedLayers(settled: Bool) {
    for (source, displayed) in zip(sourceLayers, displayedLayers) {
      let values = settled ? source : source.presentation() ?? source
      displayed.transform = values.transform
      displayed.opacity = values.opacity
      displayed.fillColor = values.fillColor
      displayed.strokeColor = values.strokeColor
      displayed.shadowColor = values.shadowColor
      displayed.shadowRadius = values.shadowRadius
      displayed.shadowOpacity = values.shadowOpacity
    }
  }

  private func refreshStatusSnapshot(settled: Bool) {
    guard !isHidden, let button = superview as? NSStatusBarButton else { return }
    withoutActions { syncDisplayedLayers(settled: settled) }
    button.needsDisplay = true
    button.displayIfNeeded()
  }

  private func startSnapshotRefresh(for duration: CFTimeInterval) {
    guard !isHidden else { return }
    refreshStatusSnapshot(settled: duration == 0 && snapshotTimer == nil)
    guard duration > 0 else { return }
    snapshotDeadline = max(snapshotDeadline, CACurrentMediaTime() + duration)
    guard snapshotTimer == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
      guard let self, !self.isHidden, self.superview != nil else {
        timer.invalidate()
        self?.stopSnapshotRefresh()
        return
      }
      let settled = CACurrentMediaTime() >= self.snapshotDeadline
      self.refreshStatusSnapshot(settled: settled)
      if settled { self.stopSnapshotRefresh() }
    }
    snapshotTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func stopSnapshotRefresh() {
    snapshotTimer?.invalidate()
    snapshotTimer = nil
    snapshotDeadline = 0
  }

  private func withoutActions(refreshSnapshot: Bool = false, _ changes: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if refreshSnapshot { newAnimationDuration = 0 }
    changes()
    CATransaction.commit()
    if refreshSnapshot { startSnapshotRefresh(for: newAnimationDuration) }
  }

  deinit { snapshotTimer?.invalidate() }
}
