import AppKit
import MachineSpiritKit
import SwiftUI

/// Icons and dominant-color tints for nodes, cached — NSWorkspace lookups
/// and pixel averaging are too heavy for a 20fps canvas without a cache.
@MainActor
enum IconStore {
  private static var icons: [String: Image] = [:]
  private static var tints: [String: Color] = [:]

  /// The terminal whose icon fronts command nodes — iTerm when present.
  static let terminalAppPath: String = {
    let iterm = "/Applications/iTerm.app"
    return FileManager.default.fileExists(atPath: iterm)
      ? iterm : "/System/Applications/Utilities/Terminal.app"
  }()

  /// The filesystem path whose icon should front this node, if any.
  static func iconPath(for node: Node) -> String? {
    guard let action = node.action else { return nil }
    if action.windowAction != nil { return nil }  // tiling keeps pure mint
    switch action {
    case .application(let path): return expand(path)
    case .folder(let path): return expand(path)
    case .command: return terminalAppPath
    case .url, .other: return nil
    }
  }

  static func icon(forPath path: String) -> Image {
    if let cached = icons[path] { return cached }
    let nsImage = NSWorkspace.shared.icon(forFile: path)
    nsImage.size = NSSize(width: 64, height: 64)
    let image = Image(nsImage: nsImage)
    icons[path] = image
    return image
  }

  /// Dominant (average) color of the file's icon, brightened so it reads on
  /// the near-black ground. Apps tint their node and its inbound trace.
  static func tint(forPath path: String) -> Color {
    if let cached = tints[path] { return cached }
    let color = computeTint(path: path)
    tints[path] = color
    return color
  }

  private static func computeTint(path: String) -> Color {
    let icon = NSWorkspace.shared.icon(forFile: path)
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return Theme.phosphor }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    icon.draw(in: NSRect(x: 0, y: 0, width: 8, height: 8))
    NSGraphicsContext.restoreGraphicsState()

    var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
    for x in 0..<8 {
      for y in 0..<8 {
        guard let pixel = bitmap.colorAt(x: x, y: y),
          pixel.alphaComponent > 0.2
        else { continue }
        red += pixel.redComponent
        green += pixel.greenComponent
        blue += pixel.blueComponent
        weight += 1
      }
    }
    guard weight > 0 else { return Theme.phosphor }

    // Brighten toward legibility on the dark board.
    let base = NSColor(
      red: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
    let lifted = base.usingColorSpace(.deviceRGB).map { c in
      NSColor(
        hue: c.hueComponent,
        saturation: min(1, c.saturationComponent * 1.15),
        brightness: max(0.62, c.brightnessComponent),
        alpha: 1)
    }
    return Color(nsColor: lifted ?? base)
  }

  private static func expand(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
  }
}
