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

  /// The icon reference for this node: a filesystem path, or
  /// `favicon:<domain>` for web-jump binds (the site's own face).
  static func iconPath(for node: Node) -> String? {
    guard let action = node.action else { return nil }
    if action.windowAction != nil { return nil }  // tiling keeps pure mint
    switch action {
    case .application(let path): return expand(path)
    case .folder(let path): return expand(path)
    case .command(let value):
      if let domain = webJumpDomain(in: value) { return "favicon:\(domain)" }
      // A command that clearly drives an app wears that app's face.
      let lowered = value.lowercased()
      if lowered.contains("iterm") || lowered.contains("tmux") {
        return "/Applications/iTerm.app"
      }
      if lowered.contains("browser") || lowered.contains("site-home") {
        return "/Applications/Safari.app"
      }
      if lowered.contains("finder") { return "/System/Library/CoreServices/Finder.app" }
      return terminalAppPath
    case .url, .other: return nil
    }
  }

  /// First domain of a web-jump bind: `osascript ~/bin/web-jump.applescript
  /// github.com` → `github.com`; comma lists take the first.
  static func webJumpDomain(in command: String) -> String? {
    guard command.contains("web-jump") else { return nil }
    let tokens = command.components(separatedBy: " ").filter { !$0.isEmpty }
    guard let scriptIndex = tokens.firstIndex(where: { $0.contains("web-jump") }),
      tokens.count > scriptIndex + 1
    else { return nil }
    let domain = tokens[scriptIndex + 1].components(separatedBy: ",")[0]
    return domain.components(separatedBy: "/")[0]
  }

  /// nil while a favicon is still in flight (the fetch bumps iconEpoch so
  /// the canvas redraws when it lands).
  static func icon(forPath path: String, state: AppState? = nil) -> Image? {
    if let cached = icons[path] { return cached }
    if path.hasPrefix("favicon:") {
      fetchFavicon(String(path.dropFirst("favicon:".count)), key: path, state: state)
      return nil
    }
    let nsImage = NSWorkspace.shared.icon(forFile: path)
    nsImage.size = NSSize(width: 64, height: 64)
    let image = Image(nsImage: nsImage)
    icons[path] = image
    return image
  }

  private static var faviconFetches: Set<String> = []

  private static func fetchFavicon(_ domain: String, key: String, state: AppState?) {
    guard !faviconFetches.contains(key),
      let url = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=64")
    else { return }
    faviconFetches.insert(key)
    Task {
      guard let (data, _) = try? await URLSession.shared.data(from: url),
        let nsImage = NSImage(data: data)
      else { return }
      nsImage.size = NSSize(width: 64, height: 64)
      icons[key] = Image(nsImage: nsImage)
      tints[key] = tint(ofImage: nsImage)
      state?.iconEpoch += 1
      state?.disturb()
    }
  }

  /// Dominant (average) color of the file's icon, brightened so it reads on
  /// the near-black ground. Apps tint their node and its inbound trace.
  static func tint(forPath path: String) -> Color {
    if let cached = tints[path] { return cached }
    if path.hasPrefix("favicon:") { return Theme.terminal }  // until it lands
    let color = tint(ofImage: NSWorkspace.shared.icon(forFile: path))
    tints[path] = color
    return color
  }

  private static func tint(ofImage icon: NSImage) -> Color {
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

  static func hasCachedIcon(_ path: String) -> Bool { icons[path] != nil }
}
