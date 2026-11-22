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
  var disks: [UserDiskVolume] = []
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
    let orderedDisks = UserDiskVolume.ordered(disks)
    for (volume, label) in zip(orderedDisks, UserDiskVolume.labels(orderedDisks)) {
      descriptions.append("\(label) (\(volume.name)) · \(volume.detail)")
    }
    if awake != nil { descriptions.append("Keep awake \(awakeStatus)") }
    return descriptions
  }
}

enum CompactBar {
  private static let spacing: CGFloat = 2
  static let separatorWidth: CGFloat = 7
  static let skullWidth: CGFloat = 20
  private static let awakeWidth: CGFloat = 12

  enum Group: Equatable {
    case t3
    case metrics
    case disks
    case timeMachine
  }

  struct Cell: Equatable {
    let label: String
    let value: String
    let width: CGFloat
    var tint: NSColor
    var group: Group = .metrics
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
    func percent(_ value: Int?) -> String {
      value.map { "\(max(0, min(100, $0)))%" } ?? "—"
    }

    var cells: [Cell] = []
    if state.t3 != .hidden {
      let value: String
      if case let .counts(working, open) = state.t3 {
        value = "\(countsValue(working))/\(countsValue(open))"
      } else { value = "—" }
      cells.append(Cell(label: "T3", value: value, width: 43, tint: foreground, group: .t3))
    }
    if state.cpu.isVisible {
      cells.append(
        Cell(label: "CPU", value: percent(state.cpu.value), width: 30, tint: foreground, group: .metrics))
    }
    if state.gpu.isVisible {
      cells.append(
        Cell(label: "GPU", value: percent(state.gpu.value), width: 30, tint: foreground, group: .metrics))
    }
    if state.memory.isVisible {
      cells.append(
        Cell(label: "RAM", value: percent(state.memory.value), width: 30, tint: foreground, group: .metrics))
      let tint: NSColor
      switch state.pressureLevel {
      case .normal: tint = state.dark ? .systemMint : NSColor(srgbRed: 0, green: 0.36, blue: 0.23, alpha: 1)
      case .warning: tint = warm
      case .critical: tint = hot
      case nil: tint = foreground
      }
      let tier: String
      switch state.pressureLevel {
      case .normal: tier = "1/3"
      case .warning: tier = "2/3"
      case .critical: tier = "3/3"
      case nil: tier = "—"
      }
      cells.append(Cell(label: "MPRS", value: tier, width: 28, tint: tint, group: .metrics))
    }
    if state.temperature.isVisible {
      let value = state.temperature.value.map { value in
        if value > 999 { return "999+" }
        if value < -99 { return "−99−" }
        return "\(value)°"
      } ?? "—"
      cells.append(
        Cell(label: "TEMP", value: value, width: 27, tint: foreground, group: .metrics))
    }
    let orderedDisks = UserDiskVolume.ordered(state.disks)
    for (volume, label) in zip(orderedDisks, UserDiskVolume.labels(orderedDisks)) {
      cells.append(
        Cell(
          label: label, value: volume.compactFree, width: 31, tint: foreground,
          group: volume.isTimeMachine ? .timeMachine : .disks))
    }
    return cells
  }

  static func separatorXPositions(for state: CompactBarState) -> [CGFloat] {
    let cells = cells(for: state)
    var x = state.skull ? Self.skullWidth : 0
    var positions: [CGFloat] = []
    for (index, cell) in cells.enumerated() {
      if index > 0 {
        if cell.group != cells[index - 1].group {
          positions.append(x + floor(separatorWidth / 2))
          x += separatorWidth
        } else {
          x += spacing
        }
      }
      x += cell.width
    }
    return positions
  }

  static func image(_ state: CompactBarState) -> NSImage {
    let foreground: NSColor = state.dark ? .white : .black
    let labelAttr = labelAttributes(foreground: foreground)
    let cells = cells(for: state)
    let skullWidth = state.skull ? Self.skullWidth : 0
    var cellsWidth: CGFloat = 0
    for (index, cell) in cells.enumerated() {
      if index > 0 {
        cellsWidth += cell.group != cells[index - 1].group ? separatorWidth : spacing
      }
      cellsWidth += cell.width
    }
    let awakeGap: CGFloat = cells.isEmpty ? 0 : spacing + 2
    let awakeSlot = state.awake == nil ? 0 : awakeGap + awakeWidth
    let width = max(4, skullWidth + cellsWidth + awakeSlot)
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
    let dividerHeight: CGFloat = 14
    let dividerY = floor((state.height - dividerHeight) / 2)
    for (index, cell) in cells.enumerated() {
      if index > 0 {
        if cell.group != cells[index - 1].group {
          let lineX = x + floor(separatorWidth / 2)
          foreground.withAlphaComponent(0.28).setFill()
          NSBezierPath.fill(NSRect(x: lineX, y: dividerY, width: 1, height: dividerHeight))
          x += separatorWidth
        } else {
          x += spacing
        }
      }
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
      x += cell.width
    }
    if let awake = state.awake {
      x += awakeGap
      // Rotate the skeletal formula a quarter turn and fit it inside the status bar.
      NSGraphicsContext.saveGraphicsState()
      let transform = NSAffineTransform()
      transform.translateX(by: x + awakeWidth / 2, yBy: size.height / 2)
      transform.rotate(byDegrees: 90)
      let scale = min(0.85, (size.height - 2) / 25)
      transform.scale(by: scale)
      transform.translateX(by: -12.5, yBy: 0)
      transform.concat()
      let bonds = NSBezierPath()
      func line(_ points: [(CGFloat, CGFloat)]) {
        for (i, p) in points.enumerated() {
          let point = NSPoint(x: p.0, y: p.1)
          if i == 0 { bonds.move(to: point) } else { bonds.line(to: point) }
        }
      }
      line([(1,0),(3.5,4.4),(8.5,4.4),(11,0),(8.5,-4.4),(3.5,-4.4),(1,0)])
      line([(11,0),(15,2.5),(19,0),(23,2.5)])
      line([(19,0),(19,-4.5)])
      bonds.appendOval(in: NSRect(x: 3.7, y: -2.3, width: 4.6, height: 4.6))
      foreground.withAlphaComponent(awake ? 1 : 0.5).setStroke()
      bonds.lineWidth = 1.15
      bonds.lineJoinStyle = .round
      bonds.stroke()
      let amine = NSBezierPath(ovalIn: NSRect(x: 21.6, y: 1.1, width: 2.8, height: 2.8))
      if awake { foreground.setFill(); amine.fill() } else { amine.stroke() }
      NSGraphicsContext.restoreGraphicsState()
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
