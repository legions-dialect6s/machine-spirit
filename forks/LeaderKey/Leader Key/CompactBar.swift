import Cocoa

/// Visible, rounded content only: identical frames never reach the status button.
struct CompactBarState: Equatable {
  var skull: Bool
  var summoned: Bool
  var counts: String
  var cpu: Int?
  var pressure: Int?  // RAM used percent; pressure level determines warning color.
  var level: Int
  var awake: Bool
  var dark: Bool
  var scale: CGFloat
  var height: CGFloat
  var gpu: Int? = nil
  var temperature: Int? = nil
  var network: String? = nil
}

enum CompactBar {
  static let warm = NSColor(srgbRed: 1, green: 176 / 255, blue: 32 / 255, alpha: 1)
  static let hot = NSColor(srgbRed: 1, green: 77 / 255, blue: 77 / 255, alpha: 1)

  static func image(_ state: CompactBarState) -> NSImage {
    let foreground: NSColor = state.dark ? .white : .black
    let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    let labelAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 7, weight: .semibold), .kern: 0.6,
      .foregroundColor: foreground.withAlphaComponent(0.60),
    ]
    func color(_ value: Int, warm: Int, hot: Int) -> NSColor {
      value >= hot ? Self.hot : value >= warm ? Self.warm : foreground
    }
    var cells: [(label: String, value: String, color: NSColor, width: CGFloat)] = []
    func cell(_ label: String, _ value: String, _ tint: NSColor, minimum: CGFloat = 28) {
      let width = max(
        minimum,
        ceil(
          max(
            (label as NSString).size(withAttributes: labelAttributes).width,
            (value as NSString).size(withAttributes: [.font: font]).width)))
      cells.append((label, value, tint, width))
    }
    let counts = state.counts.split(separator: "·")
    if counts.count == 3 {
      for (label, value) in zip(["TERM", "TMUX", "SHEOL"], counts) {
        cell(label, String(value), foreground, minimum: 25)
      }
    }
    if let cpu = state.cpu { cell("CPU", "\(cpu)%", color(cpu, warm: 70, hot: 90)) }
    if let gpu = state.gpu { cell("GPU", "\(gpu)%", color(gpu, warm: 70, hot: 90)) }
    if let ram = state.pressure {
      let tint =
        state.level == 4 || ram >= 95
        ? Self.hot : state.level == 2 || ram >= 85 ? Self.warm : foreground
      cell("RAM", "\(ram)%", tint)
    }
    if let temperature = state.temperature {
      cell("TEMP", "\(temperature)°", color(temperature, warm: 80, hot: 95))
    }
    if let network = state.network { cell("NET", network, foreground, minimum: 94) }
    let skullWidth: CGFloat = state.skull ? 21 : 0
    let width = max(
      4,
      skullWidth + cells.reduce(0) { $0 + $1.width + 4 }
        + (state.awake ? 8 : 0) - (cells.isEmpty ? 0 : 4))
    let size = NSSize(width: width, height: state.height)
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(ceil(width * state.scale)),
      pixelsHigh: Int(ceil(size.height * state.scale)), bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    if state.skull {
      let rect = NSRect(x: 0, y: (size.height - 17) / 2, width: 17, height: 17)
      NSImage(named: state.summoned ? "StatusItem-filled" : "StatusItem")?.draw(in: rect)
      if !state.summoned {
        foreground.setFill()
        rect.fill(using: .sourceAtop)
      }
    }
    var x = skullWidth
    // Two lines occupy 21 points, centered in either a 22- or 24-point menu bar.
    let bottom = floor((state.height - 21) / 2)
    for cell in cells {
      let labelWidth = (cell.label as NSString).size(withAttributes: labelAttributes).width
      (cell.label as NSString).draw(
        at: NSPoint(x: x + (cell.width - labelWidth) / 2, y: bottom + 12),
        withAttributes: labelAttributes)
      let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: cell.color]
      let valueWidth = (cell.value as NSString).size(withAttributes: attributes).width
      (cell.value as NSString).draw(
        at: NSPoint(x: x + (cell.width - valueWidth) / 2, y: bottom),
        withAttributes: attributes)
      x += cell.width + 4
    }
    if state.awake || (!state.skull && cells.isEmpty) {
      foreground.setFill()
      NSBezierPath(
        ovalIn: NSRect(
          x: state.awake ? max(0, width - 4) : 0,
          y: (size.height - 4) / 2, width: 4, height: 4)
      ).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    image.isTemplate = false  // Preserve amber/red; appearance is explicitly part of the render key.
    return image
  }
}

/// All bar numbers share one demand-driven timer. Main-thread confined.
/// No run-loop work remains after a 400 ms transition; retarget from the current value.
final class NumberTween {
  private struct Value {
    var start: Double
    var target: Double
    var began: TimeInterval
    func at(_ now: TimeInterval) -> Double {
      let t = min(1, max(0, (now - began) / 0.4))
      return start + (target - start) * (1 - pow(1 - t, 3))
    }
  }
  private var values: [String: Value] = [:]
  private(set) var timer: Timer?
  var onFrame: (() -> Void)?

  func set(_ targets: [String: Double], now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    values = values.filter { targets[$0.key] != nil }
    for (key, target) in targets where target.isFinite {
      if let old = values[key] {
        if old.target != target {
          values[key] = Value(start: old.at(now), target: target, began: now)
        }
      } else {
        values[key] = Value(start: target, target: target, began: now)
      }
    }
    if !isAnimating(at: now) {
      stop()
      return
    }
    guard timer == nil else { return }
    let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func value(_ key: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
    values[key]?.at(now)
  }

  private func isAnimating(at now: TimeInterval) -> Bool {
    values.values.contains { $0.start != $0.target && now - $0.began < 0.4 }
  }

  private func tick() {
    if !isAnimating(at: ProcessInfo.processInfo.systemUptime) { stop() }
    onFrame?()
  }

  func stop() {
    let wasRunning = timer != nil
    timer?.invalidate()
    timer = nil
    #if DEBUG
      assert(timer == nil, "A settled number tween must have no timer")
      if wasRunning { NSLog("NumberTween settled: timer=nil") }
    #endif
  }
  deinit { timer?.invalidate() }
}

extension NSMenuItem {
  static func msSectionHeader(title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(
      string: title.uppercased(),
      attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .kern: 0.7,
        .foregroundColor: NSColor.secondaryLabelColor,
      ])
    return item
  }
}
