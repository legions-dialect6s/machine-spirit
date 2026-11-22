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
  var availablePercent: Int? = nil
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
      if let availablePercent { descriptions.append("Kernel memory available \(availablePercent)%") }
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
  private static let awakeWidth: CGFloat = 25

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
      let start = lowerLimit - 25
      if value <= start { return foreground }
      if value < lowerLimit {
        return foreground.blended(withFraction: CGFloat(value - start) / 25, of: warm) ?? foreground
      }
      let fraction = min(1, CGFloat(value - lowerLimit) / CGFloat(upperLimit - lowerLimit))
      return warm.blended(withFraction: fraction, of: hot) ?? warm
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
      cells.append(Cell(label: "RAM%", value: percent(state.memory.value), width: 26,
                        tint: heat(state.memory.value, warm: 85, hot: 98)))
      let tint: NSColor
      switch state.pressureLevel {
      case .normal: tint = state.dark ? .systemMint : NSColor(srgbRed: 0, green: 0.36, blue: 0.23, alpha: 1)
      case .warning: tint = warm
      case .critical: tint = hot
      case nil: tint = foreground
      }
      cells.append(Cell(label: "AVL%", value: percent(state.availablePercent), width: 26, tint: tint))
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
      // Phenyl ring at left, then the two-carbon side chain with methyl and amine ends.
      let middle = size.height / 2
      let bonds = NSBezierPath()
      func line(_ points: [(CGFloat, CGFloat)]) {
        for (i, p) in points.enumerated() {
          let point = NSPoint(x: x + p.0, y: middle + p.1)
          if i == 0 { bonds.move(to: point) } else { bonds.line(to: point) }
        }
      }
      line([(1,0),(3.5,4.4),(8.5,4.4),(11,0),(8.5,-4.4),(3.5,-4.4),(1,0)])
      line([(11,0),(15,2.5),(19,0),(23,2.5)])
      line([(19,0),(19,-4.5)])
      bonds.appendOval(in: NSRect(x: x + 3.7, y: middle - 2.3, width: 4.6, height: 4.6))
      foreground.withAlphaComponent(awake ? 1 : 0.5).setStroke()
      bonds.lineWidth = 1.15
      bonds.lineJoinStyle = .round
      bonds.stroke()
      let amine = NSBezierPath(ovalIn: NSRect(x: x + 21.6, y: middle + 1.1, width: 2.8, height: 2.8))
      if awake { foreground.setFill(); amine.fill() } else { amine.stroke() }
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
