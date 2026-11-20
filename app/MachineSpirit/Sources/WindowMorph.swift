import AppKit
import QuartzCore

/// Presents placement intent. Only the mover can acknowledge a landing.
@MainActor
final class WindowMorph {
  static let timeout: TimeInterval = 1.8
  private let panel = OverlaySurfacePanel()
  private let outline = CALayer()
  private weak var attachedPreview: PlacementPreview?
  private var currentID: String?
  private var newestStart = -Double.infinity
  private var deadline: DispatchWorkItem?

  init() {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.addSublayer(outline)
    panel.contentView = view
    outline.anchorPoint = .zero
    outline.borderWidth = 2
    outline.cornerRadius = 10
    outline.opacity = 0
  }

  func receive(_ notification: Notification, preview: PlacementPreview? = nil) {
    guard let info = notification.userInfo, let id = info["id"] as? String,
          !id.isEmpty, id.utf8.count <= 128 else { return }
    switch info["phase"] as? String {
    case "landed": finish(id: id, duration: 0.15)
    case "cancel": finish(id: id, duration: 0.08)
    case "begin":
      guard let sent = info["time"] as? Double, sent > newestStart,
            (0...0.35).contains(ProcessInfo.processInfo.systemUptime - sent),
            let source = frame(info["from"]), let destination = frame(info["to"]) else { return }
      newestStart = sent
      deadline?.cancel()
      if let old = currentID { attachedPreview?.finishMove(id: old, duration: 0) }
      currentID = id
      attachedPreview = nil
      if let preview, preview.attachMove(id: id, destination: destination, time: sent) {
        attachedPreview = preview
        panel.orderOut(nil)
      } else if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                UserDefaults.standard.object(forKey: "msFX.windowMorph") as? Bool != false {
        show(from: source, to: destination)
      } else {
        panel.orderOut(nil)
      }
      // A crashed sender, disconnected display or refused resize must not leave a
      // green frame parked over another application.
      let work = DispatchWorkItem { [weak self] in self?.finish(id: id, duration: 0.08) }
      deadline = work
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: work)
    default: break
    }
  }

  private func frame(_ raw: Any?) -> CGRect? {
    guard let raw = raw as? String, raw.utf8.count < 180 else { return nil }
    let rect = NSRectFromString(raw)
    guard rect.width > 2, rect.height > 2,
          [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite) else { return nil }
    return rect
  }

  private func show(from source: CGRect, to destination: CGRect) {
    let screens = NSScreen.screens
    guard let screen = screens.max(by: { area($0.frame.intersection(destination)) < area($1.frame.intersection(destination)) }),
          area(destination.intersection(screen.frame)) > 4 else { panel.orderOut(nil); return }
    let endRect = destination.intersection(screen.frame)
    let startRect = source.intersection(screen.frame)
    // When crossing displays, mark the landing spot directly.
    let origin = area(startRect) > 4 ? startRect : endRect
    let canvas = origin.union(endRect)
    let from = origin.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
    let to = endRect.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    panel.setFrame(canvas, display: false)
    outline.removeAllAnimations()
    outline.contentsScale = screen.backingScaleFactor
    outline.borderColor = OverlayFX().accentColor.cgColor
    outline.position = to.origin
    outline.bounds = CGRect(origin: .zero, size: to.size)
    outline.opacity = 0.72
    if from != to {
      let move = CABasicAnimation(keyPath: "position")
      move.fromValue = from.origin; move.toValue = to.origin
      let resize = CABasicAnimation(keyPath: "bounds")
      resize.fromValue = CGRect(origin: .zero, size: from.size); resize.toValue = outline.bounds
      for animation in [move, resize] {
        animation.duration = 0.115
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        outline.add(animation, forKey: animation.keyPath)
      }
    }
    panel.orderFrontRegardless()
    CATransaction.commit()
  }

  private func finish(id: String, duration: TimeInterval) {
    guard id == currentID else { return }
    currentID = nil
    deadline?.cancel(); deadline = nil
    if let preview = attachedPreview {
      preview.finishMove(id: id, duration: duration)
      attachedPreview = nil
      return
    }
    guard panel.isVisible else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = outline.opacity
    fade.toValue = 0
    fade.duration = duration
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    CATransaction.begin(); CATransaction.setDisableActions(true)
    outline.opacity = 0
    outline.add(fade, forKey: "dismiss")
    CATransaction.commit()
    let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
    deadline = work
    DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
  }

  private func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}
