import AppKit
import ApplicationServices
import MachineSpiritKit

/// Resolve only the next configured action. A group with competing actions gives no cue.
enum PlacementIntent: Equatable {
  case mouse, aim, sized(Placement), rectangle(Placement), arrow(Placement), halfStep(Placement), cycle(next: Bool)

  var usesRectangle: Bool {
    switch self {
    case .rectangle, .cycle: true
    default: false
    }
  }

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
    case .halfUp, .halfDown: self = .halfStep(mode)
    case .displayLeft, .displayRight, .displayUp, .displayDown, .displayNext, .displayPrevious: self = .arrow(mode)
    default: return nil
    }
  }

  @MainActor func destination(window: CGRect, screens: [NSScreen],
                              windowKey: String? = nil, repeatedHorizontal: Bool = false,
                              cursor: CGPoint = NSEvent.mouseLocation) -> (SmartPlacement, NSScreen)? {
    guard let top = screens.first?.frame.maxY else { return nil }
    let frames = screens.map { flipScreenRect($0.frame, primaryTop: top) }
    let windowScreen = overlapScreen(window, screens: frames)
    let cursorScreen = screens.firstIndex { $0.frame.contains(cursor) }
    var source = windowScreen
    let prefs = UserDefaults(suiteName: "com.knollsoft.Rectangle")
    let ordered = usesRectangle ? rectangleDisplayOrder(screens, prefs: prefs) : screens
    switch self {
    case .mouse, .aim: return nil
    case .sized(let mode):
      let screen = screens[source]
      let bounds = flipScreenRect(screen.visibleFrame, primaryTop: top)
      let frame = placementFrame(mode, visibleFrame: bounds, current: window)
      let label = screenLabel(mode.previewLabel, on: screen, showDisplay: cursorScreen.map { $0 != source } ?? false)
      return (.init(frame: flipScreenRect(frame, primaryTop: top), label: label), screen)
    case .arrow(let direction):
      let xOnly = prefs?.bool(forKey: "screensOrderedByX") ?? false
      guard let index = destinationDisplay(for: direction, from: source, screens: frames, xOnly: xOnly) else { return nil }
      let from = flipScreenRect(screens[source].visibleFrame, primaryTop: top)
      let to = flipScreenRect(screens[index].visibleFrame, primaryTop: top)
      let frame = transferredFrame(window, from: from, to: to)
      return (.init(frame: flipScreenRect(frame, primaryTop: top),
                    label: transferLabel(from: screens[source], to: screens[index])), screens[index])
    case .halfStep(let mode):
      let visible = screens.map { flipScreenRect($0.visibleFrame, primaryTop: top) }
      let displayID = (screens[source].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
      let confirmedHalf: Placement? = if let windowKey, let displayID {
        PlacementState.read()?.confirmedHalf(key: windowKey, screen: displayID, frame: window,
                                             usable: visible[source], now: Date().timeIntervalSince1970)
      } else { nil }
      guard let step = verticalHalfStep(for: mode, window: window, from: source, screens: frames, visible: visible,
                                        confirmedHalf: confirmedHalf) else { return nil }
      let screen = screens[step.screen]
      let label = if step.screen != source {
        "\(step.half.previewLabel) · \(transferLabel(from: screens[source], to: screen))"
      } else {
        screenLabel(step.half.previewLabel, on: screen, showDisplay: cursorScreen.map { $0 != source } ?? false)
      }
      return (.init(frame: flipScreenRect(step.frame, primaryTop: top), label: label), screen)
    case .rectangle, .cycle:
      if prefs?.bool(forKey: "useCursorScreenDetection") == true { source = cursorScreen ?? 0 }
      else {
        let fallback = ordered.firstIndex { $0 == NSScreen.main } ?? 0
        source = screens.firstIndex(of: ordered[overlapScreen(window,
          screens: ordered.map { flipScreenRect($0.frame, primaryTop: top) }, fallback: fallback)]) ?? 0
      }
    }

    if case .cycle(let next) = self {
      guard screens.count > 1 else { return nil }
      // Rectangle orders physical displays by rows then X, with an optional X-only preference.
      guard let i = ordered.firstIndex(of: screens[source]) else { return nil }
      let screen = ordered[(i + (next ? 1 : ordered.count - 1)) % ordered.count]
      // Rectangle can restore its private last layout. Mark the destination screen itself.
      return (.init(frame: screen.visibleFrame, label: transferLabel(from: screens[windowScreen], to: screen)), screen)
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
    if ObservedWindow.matches(window, frame) {
      guard slot == .left || slot == .right else { return nil }
      if repeatedHorizontal && prefs?.integer(forKey: "subsequentExecutionMode") == 1,
         ordered.count > 1, let i = ordered.firstIndex(of: screen) {
        let delta = slot == .right ? 1 : ordered.count - 1
        let destination = ordered[(i + delta) % ordered.count]
        let opposite: Placement = slot == .right ? .left : .right
        let newFrame = placementFrame(opposite, visibleFrame: destination.visibleFrame, current: .zero)
        return (.init(frame: newFrame, label: (opposite == .left ? "left half" : "right half") + " · " +
                      transferLabel(from: screen, to: destination)), destination)
      }
      if repeatedHorizontal { return nil }
    }
    let labels: [Placement: String] = [.tl: "top-left quarter", .tr: "top-right quarter",
      .bl: "bottom-left quarter", .br: "bottom-right quarter", .left: "left half",
      .right: "right half", .top: "top half", .bottom: "bottom half"]
    let label = screenLabel(labels[slot]!, on: screen, showDisplay: cursorScreen.map { $0 != source } ?? false)
    return (.init(frame: flipScreenRect(frame, primaryTop: top), label: label), screen)
  }

  @MainActor private func rectangleDisplayOrder(_ screens: [NSScreen], prefs: UserDefaults?) -> [NSScreen] {
    let xOnly = prefs?.bool(forKey: "screensOrderedByX") == true
    return screens.sorted {
      let a = $0.frame, b = $1.frame
      if !xOnly {
        if b.maxY <= a.minY { return true }
        if a.maxY <= b.minY { return false }
      }
      return a.minX < b.minX
    }
  }
}

@MainActor func screenLabel(_ label: String, on screen: NSScreen, showDisplay: Bool) -> String {
  showDisplay ? "\(label) · \(screen.localizedName)" : label
}

@MainActor func transferLabel(from: NSScreen, to: NSScreen) -> String {
  "\(from.localizedName) → \(to.localizedName)"
}

enum LaunchCue: Equatable {
  case freshTerminal, focus(String), existingApplication(String), folder, switchedWindow
  var bundleID: String? {
    switch self {
    case .freshTerminal: "com.googlecode.iterm2"
    case .focus(let id): id
    case .existingApplication(let path):
      Bundle(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))?.bundleIdentifier
    case .folder: "com.apple.finder"
    case .switchedWindow: nil
    }
  }
  init?(action: ActionPayload?) {
    switch action {
    case .application(let path) where path.hasSuffix("/Terminal.app"): self = .focus("com.apple.Terminal")
    case .application(let path): self = .existingApplication(path)
    case .folder: self = .folder
    case .command(let cmd):
      if cmd.hasSuffix("~/bin/tmux-launch.sh") || cmd.contains("tell application \"iTerm\" to create window with default profile") {
        self = .freshTerminal
      } else if cmd.hasSuffix("~/bin/messages-find.sh") { self = .focus("com.apple.MobileSMS") }
      else if cmd.hasSuffix("~/bin/iterm-front.applescript") { self = .focus("com.googlecode.iterm2") }
      else if ["app-jump.applescript", "app-toggle.sh", "browser-window-cycle.applescript",
               "web-jump.applescript"].contains(where: { cmd.contains("~/bin/" + $0) }) { self = .switchedWindow }
      else { return nil }
    default: return nil
    }
  }
}

struct ObservedWindow: Sendable {
  let id: CGWindowID
  let frame: CGRect // WindowServer coordinates, global top-left
  var fullscreen: Bool? = nil

  static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 &&
      abs(a.maxX - b.maxX) <= 2 && abs(a.maxY - b.maxY) <= 2
  }

  /// On a notched display, native fullscreen may leave the menu-bar strip
  /// above the window while still filling the entire rest of the display.
  static func fillsFullscreenArea(_ window: CGRect, display: CGRect, usable: CGRect) -> Bool {
    abs(window.minX - display.minX) <= 2 && abs(window.maxX - display.maxX) <= 2 &&
      abs(window.maxY - display.maxY) <= 2 && window.minY >= display.minY - 2 &&
      window.minY <= usable.minY + 2
  }

  /// Metadata only, on the generic executor. Once armed, query just the original window ID.
  static func read(pid: pid_t, id: CGWindowID?) async -> Self? {
    candidates(pid: pid, id: id).first
  }

  /// AX identifies the window the command will actually move. WindowServer's
  /// z-order alone can pick a different window of the same app on another Space.
  static func focused(pid: pid_t, rectangle: Bool) async -> Self? {
    let windows = candidates(pid: pid, id: nil)
    guard AXIsProcessTrusted() else {
      if windows.count == 1 { return windows[0] }
      guard windows.count > 1, let hint = await LauncherFocusRequest.read(pid: pid),
            !Task.isCancelled else { return nil }
      let matches = candidates(pid: pid, id: nil).filter { Self.matches($0.frame, hint.frame) }
      guard matches.count == 1 else { return nil }
      return Self(id: matches[0].id, frame: hint.frame, fullscreen: hint.fullscreen)
    }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.15)
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
      var value: CFTypeRef?
      return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    func windowAttribute(_ name: String) -> AXUIElement? {
      guard let value = attribute(app, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
      return unsafeDowncast(value, to: AXUIElement.self)
    }
    let focused = windowAttribute(kAXFocusedWindowAttribute)
    let main = focused == nil && !rectangle ? windowAttribute(kAXMainWindowAttribute) : nil
    let all = focused == nil && main == nil ? attribute(app, kAXWindowsAttribute) as? [AXUIElement] : nil
    let fallback = rectangle ? all?.first : all?.first {
      attribute($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
    }
    guard let element = focused ?? main ?? fallback else { return nil }
    let names = [kAXPositionAttribute, kAXSizeAttribute, "AXFullScreen"]
    var values: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                  &values) == .success,
          let values = values as? [Any], values.count == names.count else { return nil }
    let p = values[0] as CFTypeRef, s = values[1] as CFTypeRef
    var point = CGPoint.zero, size = CGSize.zero
    guard CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
          AXValueGetValue(unsafeDowncast(p, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeDowncast(s, to: AXValue.self), .cgSize, &size) else { return nil }
    let frame = CGRect(origin: point, size: size)
    let matches = windows.filter { Self.matches($0.frame, frame) }
    guard matches.count == 1 else { return nil }
    return ObservedWindow(id: matches[0].id, frame: frame, fullscreen: values[2] as? Bool)
  }

  private static func candidates(pid: pid_t, id: CGWindowID?) -> [Self] {
    let options: CGWindowListOption = id == nil ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionIncludingWindow]
    guard let rows = CGWindowListCopyWindowInfo(options, id ?? kCGNullWindowID) as? [[String: Any]] else { return [] }
    return rows.compactMap { row in
      guard row[kCGWindowOwnerPID as String] as? Int32 == pid, row[kCGWindowLayer as String] as? Int == 0,
            let number = row[kCGWindowNumber as String] as? UInt32, id == nil || number == id,
            row[kCGWindowIsOnscreen as String] as? Bool == true,
            let values = row[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: values as CFDictionary),
            rect.width >= 40, rect.height >= 40 else { return nil }
      return ObservedWindow(id: number, frame: rect)
    }
  }
}

/// One request during preview arming, only when the board's own access cannot
/// distinguish multiple on-screen windows. Replies never carry window titles.
@MainActor
private final class LauncherFocusRequest {
  private struct Hint: Sendable {
    let frame: CGRect
    let fullscreen: Bool?
  }
  private var continuation: CheckedContinuation<Hint?, Never>?
  private var observer: NSObjectProtocol?

  fileprivate static func read(pid: pid_t) async -> (frame: CGRect, fullscreen: Bool?)? {
    let hint: Hint? = await withCheckedContinuation { continuation in
      LauncherFocusRequest().start(pid: pid, continuation: continuation)
    }
    return hint.map { ($0.frame, $0.fullscreen) }
  }

  private func start(pid: pid_t, continuation: CheckedContinuation<Hint?, Never>) {
    self.continuation = continuation
    let center = DistributedNotificationCenter.default()
    let token = UUID().uuidString
    observer = center.addObserver(
      forName: Notification.Name("com.machinespirit.leader.focus.reply"), object: token, queue: .main
    ) { [weak self] notification in
      guard notification.userInfo?["pid"] as? String == String(pid),
            let payload = notification.userInfo?["frame"] as? String else { return }
      let fields = payload.split(separator: ",", omittingEmptySubsequences: false)
      let values = fields.compactMap { Double($0) }
      guard fields.count == 4, values.count == 4, values.allSatisfy(\.isFinite),
            values[2] >= 40, values[3] >= 40 else { return }
      let frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
      let rawFullscreen = notification.userInfo?["fullscreen"] as? String
      let fullscreen = rawFullscreen == "1" ? true : rawFullscreen == "0" ? false : nil
      MainActor.assumeIsolated { self?.finish(Hint(frame: frame, fullscreen: fullscreen)) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(190)) { self.finish(nil) }
    center.postNotificationName(Notification.Name("com.machinespirit.leader.focus.request"),
                                object: token, userInfo: ["pid": String(pid)], deliverImmediately: true)
  }

  private func finish(_ hint: Hint?) {
    if let observer {
      DistributedNotificationCenter.default().removeObserver(observer)
      self.observer = nil
    }
    let pending = continuation
    continuation = nil
    pending?.resume(returning: hint)
  }
}
