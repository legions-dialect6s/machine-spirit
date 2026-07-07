import AppKit
import SwiftTerm

/// Parses the repo's captured iTerm scheme (`config/iterm2/hacker.itermcolors`)
/// and dresses the embedded ledger in it — the pane should look exactly like
/// the iTerm original.
enum ITermColors {
  static func apply(to terminal: LocalProcessTerminalView) {
    guard let scheme = load() else {
      terminal.nativeBackgroundColor = NSColor(Theme.ground)
      terminal.nativeForegroundColor = NSColor(Theme.phosphor)
      return
    }
    var ansi: [SwiftTerm.Color] = []
    for index in 0..<16 {
      if let color = scheme["Ansi \(index) Color"] {
        ansi.append(swiftTermColor(color))
      }
    }
    if ansi.count == 16 { terminal.installColors(ansi) }
    if let background = scheme["Background Color"] {
      terminal.nativeBackgroundColor = background
    }
    if let foreground = scheme["Foreground Color"] {
      terminal.nativeForegroundColor = foreground
    }
    if let cursor = scheme["Cursor Color"] {
      terminal.caretColor = cursor
    }
  }

  private static func load() -> [String: NSColor]? {
    let path = repoColorsPath()
    guard let data = FileManager.default.contents(atPath: path),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dict = plist as? [String: [String: Any]]
    else { return nil }

    var colors: [String: NSColor] = [:]
    for (key, component) in dict {
      let red = (component["Red Component"] as? Double) ?? 0
      let green = (component["Green Component"] as? Double) ?? 0
      let blue = (component["Blue Component"] as? Double) ?? 0
      colors[key] = NSColor(red: red, green: green, blue: blue, alpha: 1)
    }
    return colors
  }

  private static func repoColorsPath() -> String {
    URL(fileURLWithPath: #filePath)  // …/app/MachineSpirit/Sources/ITermColors.swift
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("config/iterm2/hacker.itermcolors").path
  }

  private static func swiftTermColor(_ color: NSColor) -> SwiftTerm.Color {
    let rgb = color.usingColorSpace(.deviceRGB) ?? color
    return SwiftTerm.Color(
      red: UInt16(rgb.redComponent * 65535),
      green: UInt16(rgb.greenComponent * 65535),
      blue: UInt16(rgb.blueComponent * 65535))
  }
}
