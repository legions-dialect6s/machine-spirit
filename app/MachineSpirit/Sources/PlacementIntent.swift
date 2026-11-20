import AppKit
import MachineSpiritKit

/// Resolve only the next configured action. A group with competing actions gives no cue.
enum PlacementIntent: Equatable {
  case mouse, aim, sized(Placement), rectangle(Placement), arrow(Placement), cycle(next: Bool)

  init?(action: ActionPayload?) {
    guard let action else { return nil }
    if let name = action.windowAction {
      switch name {
      case "next-display", "previous-display": self = .cycle(next: name == "next-display")
      default:
        let slots: [String: Placement] = ["top-left": .tl, "top-right": .tr, "bottom-left": .bl,
          "bottom-right": .br, "left-half": .left, "right-half": .right, "top-half": .top, "bottom-half": .bottom]
        guard let slot = slots[name] else { return nil }
        self = .rectangle(slot)
      }
      return
    }
    guard case .command(let command) = action else { return nil }
    var words = command.split(whereSeparator: \.isWhitespace)[...]
    if words.first == "~/bin/run-quiet.sh" { words = words.dropFirst() }
    guard words.count == 4, words.starts(with: ["~/bin/ms", "win", "place"]),
          let mode = Placement(rawValue: String(words.last!)) else { return nil }
    switch mode {
    case .smart: self = .mouse
    case .aim: self = .aim
    case .amm, .max: self = .sized(mode)
    case .displayLeft, .displayRight, .displayUp, .displayDown: self = .arrow(mode)
    default: return nil
    }
  }

  @MainActor func destination(window: CGRect, screens: [NSScreen]) -> (SmartPlacement, NSScreen)? {
    guard let top = screens.first?.frame.maxY else { return nil }
    let frames = screens.map { flipScreenRect($0.frame, primaryTop: top) }
    var source = overlapScreen(window, screens: frames)
    let prefs = UserDefaults(suiteName: "com.knollsoft.Rectangle")
    switch self {
    case .mouse, .aim: return nil
    case .sized(let mode):
      let screen = screens[source]
      let bounds = flipScreenRect(screen.visibleFrame, primaryTop: top)
      let frame = placementFrame(mode, visibleFrame: bounds, current: window)
      return (.init(frame: flipScreenRect(frame, primaryTop: top), label: mode.previewLabel), screen)
    case .arrow(let direction):
      guard let index = destinationDisplay(for: direction, from: source, screens: frames) else { return nil }
      let from = flipScreenRect(screens[source].visibleFrame, primaryTop: top)
      let to = flipScreenRect(screens[index].visibleFrame, primaryTop: top)
      let frame = transferredFrame(window, from: from, to: to)
      return (.init(frame: flipScreenRect(frame, primaryTop: top), label: screens[index].localizedName), screens[index])
    case .rectangle, .cycle:
      if prefs?.bool(forKey: "useCursorScreenDetection") == true,
         let cursor = screens.firstIndex(where: { $0.frame.contains(NSEvent.mouseLocation) }) { source = cursor }
    }

    if case .cycle(let next) = self {
      guard screens.count > 1 else { return nil }
      // Rectangle orders physical displays by rows then X, with an optional X-only preference.
      let xOnly = prefs?.bool(forKey: "screensOrderedByX") == true
      let ordered = screens.indices.sorted {
        let a = screens[$0].frame, b = screens[$1].frame
        if !xOnly {
          if b.maxY <= a.minY { return true }
          if a.maxY <= b.minY { return false }
        }
        return a.minX < b.minX
      }
      guard let i = ordered.firstIndex(of: source) else { return nil }
      let screen = screens[ordered[(i + (next ? 1 : ordered.count - 1)) % ordered.count]]
      // Rectangle can restore its private last layout. Mark the destination screen itself.
      return (.init(frame: screen.visibleFrame, label: screen.localizedName), screen)
    }

    guard case .rectangle(let slot) = self else { return nil }
    // Custom Rectangle layouts may include user ratios, gaps, Stage Manager or a sidebar.
    // In those layouts its own command remains authoritative and no speculative box is drawn.
    let adjusted = ["gapSize", "screenEdgeGapTop", "screenEdgeGapTopNotch", "screenEdgeGapLeft",
                    "screenEdgeGapBottom", "screenEdgeGapRight", "todoMode", "combinedDisplayMode"]
    guard !adjusted.contains(where: { (prefs?.double(forKey: $0) ?? 0) != 0 }),
          !["horizontalSplitRatio", "verticalSplitRatio"].contains(where: {
            (prefs?.object(forKey: $0) as? NSNumber)?.doubleValue ?? 50 != 50
          }), UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") != true else { return nil }
    let screen = screens[source]
    let bounds = flipScreenRect(screen.visibleFrame, primaryTop: top)
    let frame = placementFrame(slot, visibleFrame: bounds, current: window)
    // A repeated Rectangle action can cycle to a different display or size based on private history.
    guard !ObservedWindow.matches(window, frame) else { return nil }
    let labels: [Placement: String] = [.tl: "top-left quarter", .tr: "top-right quarter",
      .bl: "bottom-left quarter", .br: "bottom-right quarter", .left: "left half",
      .right: "right half", .top: "top half", .bottom: "bottom half"]
    return (.init(frame: flipScreenRect(frame, primaryTop: top), label: labels[slot]!), screen)
  }
}

enum LaunchCue: Equatable {
  case freshTerminal, focus(String)
  var bundleID: String {
    switch self {
    case .freshTerminal: "com.googlecode.iterm2"
    case .focus(let id): id
    }
  }
  init?(action: ActionPayload?) {
    switch action {
    case .application(let path) where path.hasSuffix("/Terminal.app"): self = .focus("com.apple.Terminal")
    case .command(let cmd):
      if cmd.hasSuffix("~/bin/tmux-launch.sh") || cmd.contains("tell application \"iTerm\" to create window with default profile") {
        self = .freshTerminal
      } else if cmd.hasSuffix("~/bin/messages-find.sh") { self = .focus("com.apple.MobileSMS") }
      else if cmd.hasSuffix("~/bin/iterm-front.applescript") { self = .focus("com.googlecode.iterm2") }
      else { return nil }
    default: return nil
    }
  }
}

struct ObservedWindow: Sendable {
  let id: CGWindowID
  let frame: CGRect // WindowServer coordinates, global top-left

  static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 &&
      abs(a.maxX - b.maxX) <= 2 && abs(a.maxY - b.maxY) <= 2
  }

  /// Metadata only, on the generic executor. Once armed, query just the original window ID.
  static func read(pid: pid_t, id: CGWindowID?) async -> Self? {
    let options: CGWindowListOption = id == nil ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionIncludingWindow]
    guard let rows = CGWindowListCopyWindowInfo(options, id ?? kCGNullWindowID) as? [[String: Any]] else { return nil }
    for row in rows {
      guard row[kCGWindowOwnerPID as String] as? Int32 == pid, row[kCGWindowLayer as String] as? Int == 0,
            let number = row[kCGWindowNumber as String] as? UInt32, id == nil || number == id,
            row[kCGWindowIsOnscreen as String] as? Bool == true,
            let values = row[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: values as CFDictionary),
            rect.width >= 40, rect.height >= 40 else { continue }
      return ObservedWindow(id: number, frame: rect)
    }
    return nil
  }
}
