import Cocoa

/// Only configured segments reserve space. A missing sample keeps its slot.
struct CompactBarState: Equatable {
  enum Sample: Equatable {
    case hidden
    case unavailable
    case value(Int)

    var isVisible: Bool { self != .hidden }
    var value: Int? {
      if case let .value(value) = self { return value }
      return nil
    }

    init(enabled: Bool, value: Int?) {
      self = enabled ? value.map(Self.value) ?? .unavailable : .hidden
    }
  }

  enum Pressure: Int {
    case normal = 1
    case warning = 2
    case critical = 4

    var name: String {
      switch self {
      case .normal: return "normal"
      case .warning: return "warning"
      case .critical: return "critical"
      }
    }
  }

  var skull: Bool
  enum TaskCount: Equatable {
    case hidden, unavailable
    case counts(working: Int, open: Int)
  }
  var t3: TaskCount
  var cpu: Sample
  var gpu: Sample
  var memory: Sample
  var pressureLevel: Pressure?
  var temperature: Sample
  var awake: Bool?
  var dark: Bool
  var scale: CGFloat
  var height: CGFloat

  func descriptions(awakeStatus: String) -> [String] {
    var descriptions: [String] = []
    func describe(_ label: String, _ sample: Sample, unit: String) {
      guard sample.isVisible else { return }
      descriptions.append("\(label) " + (sample.value.map { "\($0)\(unit)" } ?? "unavailable"))
    }
    switch t3 {
    case .hidden: break
    case .unavailable: descriptions.append("T3 task data unavailable")
    case .counts(let working, let open): descriptions.append("T3 tasks: \(working) working / \(open) open")
    }
    describe("CPU", cpu, unit: "%")
    describe("GPU", gpu, unit: "%")
    describe("RAM used", memory, unit: "%")
    if memory.isVisible {
      descriptions.append("Memory pressure \(pressureLevel?.name ?? "unavailable")")
    }
    describe("Temperature", temperature, unit: " degrees Celsius")
    if awake != nil { descriptions.append("Keep awake \(awakeStatus)") }
    return descriptions
  }
}

enum CompactBar {
  private static let spacing: CGFloat = 2
  static let skullWidth: CGFloat = 20
  private static let awakeWidth: CGFloat = 17

  struct Cell: Equatable {
    let label: String
    let value: String
    let width: CGFloat
    var tint: NSColor
  }

  private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
  private static func labelAttributes(foreground: NSColor) -> [NSAttributedString.Key: Any] {
    [
      .font: NSFont.systemFont(ofSize: 7, weight: .semibold), .kern: 0.6,
      .foregroundColor: foreground.withAlphaComponent(0.72),
    ]
  }

  static func countsValue(_ count: Int) -> String {
    count > 99 ? "99+" : String(count)
  }

  static func cells(for state: CompactBarState) -> [Cell] {
    let foreground: NSColor = state.dark ? .white : .black
    let warm = state.dark ? NSColor(srgbRed: 1, green: 0.70, blue: 0.20, alpha: 1)
      : NSColor(srgbRed: 0.52, green: 0.29, blue: 0.02, alpha: 1)
    let hot = state.dark ? NSColor(srgbRed: 1, green: 0.38, blue: 0.38, alpha: 1)
      : NSColor(srgbRed: 0.65, green: 0.10, blue: 0.15, alpha: 1)
    func heat(_ value: Int?, warm lowerLimit: Int, hot upperLimit: Int) -> NSColor {
      guard let value else { return foreground }
      return value >= upperLimit ? hot : value >= lowerLimit ? warm : foreground
    }
    func percent(_ value: Int?) -> String {
      value.map { String(max(0, min(100, $0))) } ?? "—"
    }

    var cells: [Cell] = []
    if state.t3 != .hidden {
      let value: String
      if case let .counts(working, open) = state.t3 {
        value = "\(countsValue(working))/\(countsValue(open))"
      } else { value = "—" }
      cells.append(Cell(label: "T3", value: value, width: 43, tint: foreground))
    }
    if state.cpu.isVisible {
      cells.append(Cell(label: "CPU%", value: percent(state.cpu.value), width: 26,
                        tint: heat(state.cpu.value, warm: 70, hot: 90)))
    }
    if state.gpu.isVisible {
      cells.append(Cell(label: "GPU%", value: percent(state.gpu.value), width: 26,
                        tint: heat(state.gpu.value, warm: 70, hot: 90)))
    }
    if state.memory.isVisible {
      cells.append(Cell(label: "RAM%", value: percent(state.memory.value), width: 26, tint: foreground))
      let pressure: (String, NSColor)
      switch state.pressureLevel {
      case .normal: pressure = ("OK", foreground)
      case .warning: pressure = ("WARN", warm)
      case .critical: pressure = ("CRIT", hot)
      case nil: pressure = ("—", foreground)
      }
      cells.append(Cell(label: "MPRS", value: pressure.0, width: 34, tint: pressure.1))
    }
    if state.temperature.isVisible {
      let value = state.temperature.value.map { value in
        if value > 999 { return "999+" }
        if value < -99 { return "−99−" }
        return "\(value)°"
      } ?? "—"
      cells.append(Cell(label: "TEMP", value: value, width: 27,
                        tint: heat(state.temperature.value, warm: 80, hot: 95)))
    }
    return cells
  }

  static func image(_ state: CompactBarState) -> NSImage {
    let foreground: NSColor = state.dark ? .white : .black
    let labelAttr = labelAttributes(foreground: foreground)
    let cells = cells(for: state)
    let skullWidth = state.skull ? Self.skullWidth : 0
    let awakeSlot = state.awake == nil ? 0 : awakeWidth + spacing
    let width = max(4, skullWidth + awakeSlot
      + cells.reduce(0) { $0 + $1.width + spacing }
      - (state.awake == nil && cells.isEmpty ? 0 : spacing))
    let size = NSSize(width: width, height: state.height)
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(ceil(width * state.scale)),
      pixelsHigh: Int(ceil(size.height * state.scale)), bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // The status button's skull layer uses this reserved leading slot.
    var x = skullWidth
    let bottom = floor((state.height - 21) / 2)
    for cell in cells {
      let labelWidth = (cell.label as NSString).size(withAttributes: labelAttr).width
      let labelX = x + (cell.width - labelWidth) / 2
      (cell.label as NSString).draw(
        at: NSPoint(x: labelX, y: bottom + 12),
        withAttributes: labelAttr)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: valueFont, .foregroundColor: cell.tint,
      ]
      let valueWidth = (cell.value as NSString).size(withAttributes: attributes).width
      let valueX = x + (cell.width - valueWidth) / 2
      (cell.value as NSString).draw(at: NSPoint(x: valueX, y: bottom), withAttributes: attributes)
      x += cell.width + spacing
    }
    if let awake = state.awake {
      let rect = NSRect(x: x + 1, y: (size.height - 7) / 2, width: 15, height: 7)
      let capsule = NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5)
      NSGraphicsContext.saveGraphicsState()
      capsule.addClip()
      if awake {
        foreground.withAlphaComponent(0.35).setFill()
        rect.fill()
        foreground.setFill()
        NSRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height).fill()
      }
      NSGraphicsContext.restoreGraphicsState()
      foreground.withAlphaComponent(awake ? 0.95 : 0.5).setStroke()
      capsule.lineWidth = 1
      capsule.stroke()
    } else if !state.skull && cells.isEmpty {
      foreground.setFill()
      NSBezierPath(ovalIn: NSRect(x: 0, y: (size.height - 4) / 2, width: 4, height: 4)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    image.isTemplate = false
    return image
  }

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
