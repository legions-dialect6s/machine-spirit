import Cocoa
import Combine
import Defaults
import SwiftUI

enum KeyHelpers: UInt16 {
  case enter = 36
  case tab = 48
  case space = 49
  case backspace = 51
  case escape = 53
  case upArrow = 126
  case downArrow = 125
  case leftArrow = 123
  case rightArrow = 124
}

class Controller {
  var userState: UserState
  var userConfig: UserConfig

  var window: MainWindow!
  var cheatsheetWindow: NSWindow!
  private var cheatsheetTimer: Timer?

  private var cancellables = Set<AnyCancellable>()

  init(userState: UserState, userConfig: UserConfig) {
    self.userState = userState
    self.userConfig = userConfig

    Task {
      for await value in Defaults.updates(.theme) {
        let windowClass = Theme.classFor(value)
        self.window = await windowClass.init(controller: self)
      }
    }

    Events.sink { event in
      switch event {
      case .didReload:
        // This should all be handled by the themes
        self.userState.isShowingRefreshState = true
        self.show()
        // Delay for 4 * 300ms to wait for animation to be noticeable
        delay(Int(Pulsate.singleDurationS * 1000) * 3) {
          self.hide()
          self.userState.isShowingRefreshState = false
        }
      default: break
      }
    }.store(in: &cancellables)

    self.cheatsheetWindow = Cheatsheet.createWindow(for: userState)
  }

  func show() {
    Events.send(.willActivate)

    // The theme window is created asynchronously (Controller.init observes
    // .theme), so it can still be nil right after launch. A summon that races
    // that init — e.g. a leaderkey:// URL fired at login — must no-op, not trap
    // on the implicitly-unwrapped `window`.
    guard let window else {
      Events.send(.didActivate)
      return
    }

    // Never fall back to a bare `NSScreen()` — that produces a display-less
    // phantom whose `.frame` traps (SIGTRAP) inside AppKit when a theme calls
    // `screen.center()`. `getNSScreen()` legitimately returns nil (pointer in a
    // gap for `.mouse`, no key window for `.activeWindow`), so chain to a real
    // screen and bail only when the Mac genuinely has no display at all.
    guard let screen = Defaults[.screen].getNSScreen() ?? NSScreen.main ?? NSScreen.screens.first else {
      Events.send(.didActivate)
      return
    }
    window.show(on: screen) {
      Events.send(.didActivate)
    }

    if !window.hasCheatsheet || userState.isShowingRefreshState {
      return
    }

    switch Defaults[.autoOpenCheatsheet] {
    case .always:
      showCheatsheet()
    case .delay:
      scheduleCheatsheet()
    default: break
    }
  }

  func hide(afterClose: (() -> Void)? = nil) {
    guard let window else {
      afterClose?()
      return
    }
    Events.send(.willDeactivate)

    window.hide {
      self.clear()
      afterClose?()
      Events.send(.didDeactivate)
    }

    cheatsheetWindow?.orderOut(nil)
    cheatsheetTimer?.invalidate()
  }

  func keyDown(with event: NSEvent) {
    // Reset the delay timer
    if Defaults[.autoOpenCheatsheet] == .delay {
      scheduleCheatsheet()
    }

    if event.modifierFlags.contains(.command) {
      switch event.charactersIgnoringModifiers {
      case ",":
        NSApp.sendAction(
          #selector(AppDelegate.settingsMenuItemActionHandler(_:)), to: nil,
          from: nil)
        hide()
        return
      case "w":
        hide()
        return
      case "q":
        NSApp.terminate(nil)
        return
      default:
        break
      }
    }

    switch event.keyCode {
    case KeyHelpers.backspace.rawValue:
      clear()
      delay(1) {
        self.positionCheatsheetWindow()
      }
    case KeyHelpers.escape.rawValue:
      window.resignKey()
    default:
      guard let char = charForEvent(event) else { return }
      handleKey(char, withModifiers: event.modifierFlags)
    }
  }

  func handleKey(_ key: String, withModifiers modifiers: NSEvent.ModifierFlags? = nil, execute: Bool = true) {
    if key == "?" {
      showCheatsheet()
      return
    }

    let list =
      (userState.currentGroup != nil)
      ? userState.currentGroup : userConfig.root

    let hit = list?.actions.first { item in
      switch item {
      case .group(let group):
        // Normalize both keys for comparison
        let groupKey = KeyMaps.glyph(for: group.key ?? "") ?? group.key ?? ""
        let inputKey = KeyMaps.glyph(for: key) ?? key
        if groupKey == inputKey {
          return true
        }
      case .action(let action):
        // Normalize both keys for comparison
        let actionKey = KeyMaps.glyph(for: action.key ?? "") ?? action.key ?? ""
        let inputKey = KeyMaps.glyph(for: key) ?? key
        if actionKey == inputKey {
          return true
        }
      }
      return false
    }

    switch hit {
    case .action(let action):
      if execute {
        // machine-spirit fork (#36): tell the board a bind fired, with its
        // full structural key path — BEFORE hide(), which clears
        // navigationPath. Non-blocking, silent-failing: it must never
        // delay or break the bind.
        fireBoardPing(actionKey: action.key)
        if let mods = modifiers, isInStickyMode(mods) {
          runAction(action)
        } else {
          hide {
            self.runAction(action)
          }
        }
      }
      // If execute is false, just stay visible showing the matched action
    case .group(let group):
      if execute, let mods = modifiers, shouldRunGroupSequenceWithModifiers(mods) {
        hide {
          self.runGroup(group)
        }
      } else {
        userState.display = group.key
        userState.navigateToGroup(group)
      }
    case .none:
      window.notFound()
    }

    // Why do we need to wait here?
    delay(1) {
      self.positionCheatsheetWindow()
    }
  }

  private func shouldRunGroupSequence(_ event: NSEvent) -> Bool {
    return shouldRunGroupSequenceWithModifiers(event.modifierFlags)
  }

  private func shouldRunGroupSequenceWithModifiers(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
    let config = Defaults[.modifierKeyConfiguration]

    switch config {
    case .controlGroupOptionSticky:
      return modifierFlags.contains(.control)
    case .optionGroupControlSticky:
      return modifierFlags.contains(.option)
    }
  }

  private func isInStickyMode(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
    let config = Defaults[.modifierKeyConfiguration]

    switch config {
    case .controlGroupOptionSticky:
      return modifierFlags.contains(.option)
    case .optionGroupControlSticky:
      return modifierFlags.contains(.control)
    }
  }

  internal func charForEvent(_ event: NSEvent) -> String? {
    let forceEnglish = Defaults[.forceEnglishKeyboardLayout]

    // 1. If the user forces English, or if the key is non-printable,
    //    fall back to the hard-coded map.
    if forceEnglish {
      return englishGlyph(for: event)
    }

    // 2. For special keys like Enter, always use the mapped glyph
    if let entry = KeyMaps.entry(for: event.keyCode) {
      // For Enter, Space, Tab, arrows, etc. - use the glyph representation
      if event.keyCode == KeyHelpers.enter.rawValue || event.keyCode == KeyHelpers.space.rawValue
        || event.keyCode == KeyHelpers.tab.rawValue
        || event.keyCode == KeyHelpers.leftArrow.rawValue
        || event.keyCode == KeyHelpers.rightArrow.rawValue
        || event.keyCode == KeyHelpers.upArrow.rawValue
        || event.keyCode == KeyHelpers.downArrow.rawValue
      {
        return entry.glyph
      }
    }

    // 3. Use the system-translated character for regular keys.
    if let printable = event.charactersIgnoringModifiers,
      !printable.isEmpty,
      printable.unicodeScalars.first?.isASCII ?? false
    {
      return printable  // already contains correct case
    }

    // 4. For arrows, ␣, ⌫ … use map as last resort.
    return englishGlyph(for: event)
  }

  private func englishGlyph(for event: NSEvent) -> String? {
    guard let entry = KeyMaps.entry(for: event.keyCode) else {
      return event.charactersIgnoringModifiers
    }
    if entry.glyph.first?.isLetter == true && !entry.isReserved {
      return event.modifierFlags.contains(.shift)
        ? entry.glyph.uppercased()
        : entry.glyph
    }
    return entry.glyph
  }

  private func positionCheatsheetWindow() {
    guard let mainWindow = window, let cheatsheet = cheatsheetWindow else {
      return
    }

    cheatsheet.setFrameOrigin(
      mainWindow.cheatsheetOrigin(cheatsheetSize: cheatsheet.frame.size))
  }

  private func showCheatsheet() {
    if !window.hasCheatsheet {
      return
    }
    positionCheatsheetWindow()
    cheatsheetWindow?.orderFront(nil)
  }

  private func scheduleCheatsheet() {
    cheatsheetTimer?.invalidate()

    cheatsheetTimer = Timer.scheduledTimer(
      withTimeInterval: Double(Defaults[.cheatsheetDelayMS]) / 1000.0, repeats: false
    ) { [weak self] _ in
      self?.showCheatsheet()
    }
  }

  private func runGroup(_ group: Group) {
    for groupOrAction in group.actions {
      switch groupOrAction {
      case .group(let group):
        runGroup(group)
      case .action(let action):
        runAction(action)
      }
    }
  }

  private func runAction(_ action: Action) {
    switch action.type {
    case .application:
      NSWorkspace.shared.openApplication(
        at: URL(fileURLWithPath: action.value),
        configuration: NSWorkspace.OpenConfiguration())
    case .url:
      openURL(action)
    case .command:
      CommandRunner.run(action.value)
    case .folder:
      let path: String = (action.value as NSString).expandingTildeInPath
      NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    default:
      print("\(action.type) unknown")
    }

    if window.isVisible {
      window.makeKeyAndOrderFront(nil)
    }
  }

  private func clear() {
    userState.clear()
  }

  /// machine-spirit fork (#36): fire `machinespirit://fired?path=s/s/w/s`
  /// so the board pulses the route of the bind that just ran. The path is
  /// the group keys walked so far plus this action's key — the same
  /// structural key path the app resolves against its imported model.
  ///
  /// Contract: this can NEVER delay or break a bind. It only fires if the
  /// board is ALREADY running (never launches it), builds the URL without
  /// activating anything, and swallows every failure.
  private static let boardBundleID = "com.machinespirit.MachineSpirit"
  private func fireBoardPing(actionKey: String?) {
    guard let actionKey else { return }
    let boardRunning = NSWorkspace.shared.runningApplications.contains {
      $0.bundleIdentifier == Self.boardBundleID
    }
    guard boardRunning else { return }

    var keys = userState.navigationPath.compactMap { $0.key }
    keys.append(actionKey)

    var components = URLComponents()
    components.scheme = "machinespirit"
    components.host = "fired"
    components.queryItems = [URLQueryItem(name: "path", value: keys.joined(separator: "/"))]
    guard let url = components.url else { return }

    let config = NSWorkspace.OpenConfiguration()
    config.activates = false  // pulse without stealing focus from the user
    NSWorkspace.shared.open(url, configuration: config) { _, _ in }
  }

  private func openURL(_ action: Action) {
    guard let url = URL(string: action.value) else {
      showAlert(
        title: "Invalid URL", message: "Failed to parse URL: \(action.value)")
      return
    }

    guard let scheme = url.scheme else {
      showAlert(
        title: "Invalid URL",
        message:
          "URL is missing protocol (e.g. https://, raycast://): \(action.value)"
      )
      return
    }

    if scheme == "http" || scheme == "https" {
      NSWorkspace.shared.open(
        url,
        configuration: NSWorkspace.OpenConfiguration())
    } else {
      NSWorkspace.shared.open(
        url,
        configuration: DontActivateConfiguration.shared.configuration)
    }
  }

  private func showAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}

class DontActivateConfiguration {
  let configuration = NSWorkspace.OpenConfiguration()

  static var shared = DontActivateConfiguration()

  init() {
    configuration.activates = false
  }
}

extension Screen {
  func getNSScreen() -> NSScreen? {
    switch self {
    case .primary:
      return NSScreen.screens.first
    case .mouse:
      // Pointer can sit in a gap between displays (or off-screen); fall back to
      // the active/main screen rather than returning nil.
      return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        ?? NSScreen.main
    case .activeWindow:
      return NSScreen.main
    }
  }
}
