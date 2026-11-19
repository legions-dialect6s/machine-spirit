import Cocoa

/// Render state contains only visible content. Hidden segments never trigger a setter.
struct CompactBarState: Equatable {
  var skull: Bool
  var summoned: Bool
  var counts: String
  var cpu: Int?
  var pressure: Int?
  var level: Int
  var awake: Bool
  var dark: Bool
  var scale: CGFloat
  var height: CGFloat
}

enum CompactBar {
  static func image(_ state: CompactBarState) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    let colored = state.summoned || (state.pressure != nil && state.level != 1)
    let foreground: NSColor = colored ? (state.dark ? .white : .black) : .black
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
    var segments: [(String, CGFloat, Int)] = []
    if state.skull { segments.append(("", 17, 0)) }
    if !state.counts.isEmpty {
      segments.append(
        (state.counts, ceil((state.counts as NSString).size(withAttributes: attributes).width), 1))
    }
    if let cpu = state.cpu {
      let text = "\(cpu)%"
      segments.append((text, ceil((text as NSString).size(withAttributes: attributes).width), 2))
    }
    if let pressure = state.pressure {
      let text = "\(pressure)%"
      segments.append((text, ceil((text as NSString).size(withAttributes: attributes).width), 3))
    }
    if state.awake { segments.append(("", 4, 4)) }
    // All toggles off still leaves a tiny discoverable menu target.
    if segments.isEmpty { segments.append(("", 4, 4)) }
    let width = segments.reduce(CGFloat(0)) { $0 + $1.1 } + CGFloat(segments.count - 1) * 4
    let size = NSSize(width: width, height: state.height)
    let scale = state.scale
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(ceil(width * scale)),
      pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    var x: CGFloat = 0
    for (text, segmentWidth, kind) in segments {
      if kind == 0 {
        let mark = NSImage(named: state.summoned ? "StatusItem-filled" : "StatusItem")
        let rect = NSRect(x: x, y: (size.height - 17) / 2, width: 17, height: 17)
        mark?.draw(in: rect)
        if !state.summoned {
          foreground.setFill()
          rect.fill(using: .sourceAtop)
        }
      } else if kind == 4 {
        foreground.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: (size.height - 4) / 2, width: 4, height: 4)).fill()
      } else {
        let textHeight = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(
          at: NSPoint(x: x, y: floor((size.height - textHeight) / 2)), withAttributes: attributes)
        if kind == 3 {
          (state.level == 4 ? NSColor.systemRed : state.level == 2 ? .systemOrange : foreground)
            .setFill()
          NSRect(
            x: x, y: max(0, floor((size.height - textHeight) / 2) - 2), width: segmentWidth,
            height: 3 / scale
          ).fill()
        }
      }
      x += segmentWidth + 4
    }
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    image.isTemplate = !colored
    return image
  }
}

extension NSMenuItem {
  static func msSectionHeader(title: String) -> NSMenuItem {
    if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }
}
