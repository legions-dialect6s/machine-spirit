import Cocoa
import os.log
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
  private var boardScreenFrame: NSRect = .zero
  private var boardPanelShown = false
  private var boardFocusObserver: NSObjectProtocol?
  private let boardFocusQueue = DispatchQueue(
    label: "com.machinespirit.leader.focus", qos: .userInitiated)

  private var cancellables = Set<AnyCancellable>()

  // MARK: machine-spirit hold mode
  // When ⇪ (F19) is still physically held as an action fires, the (non-
  // activating, so the target app keeps focus) panel stays key and routes
  // further presses to the action's `hold` command until ⇪ is released.
  private(set) var holdAction: Action?
  private var holdPath: [String] = []
  private var holdCount = 0
  private var holdSpaceCount = 0
  private var holdWatch: Timer?
  private var holdTap: CFMachPort?
  private var holdTapSource: CFRunLoopSource?
  private var lastFired: (key: String, at: Date, count: Int)?
  static let leaderKeyCode: CGKeyCode = 80  // F19 (Karabiner maps ⇪ → F19)

  init(userState: UserState, userConfig: UserConfig) {
    self.userState = userState
    self.userConfig = userConfig
    userState.navigationDidChange = { [weak self] in
      guard let self else { return }
      // Backspace can return an open panel to the root (an empty path).
      self.postBoardNavigation(hidden: !self.boardPanelShown)
    }

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

    boardFocusObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("com.machinespirit.leader.focus.request"), object: nil, queue: .main
    ) { [weak self] notification in
      guard let self, let token = notification.object as? String, UUID(uuidString: token) != nil,
        let text = notification.userInfo?["pid"] as? String, let pid = pid_t(text), pid > 0,
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
      else { return }
      self.boardFocusQueue.async { Self.replyWithBoardFocus(pid: pid, token: token) }
    }
  }

  deinit {
    if let boardFocusObserver {
      DistributedNotificationCenter.default().removeObserver(boardFocusObserver)
    }
  }

  private static func replyWithBoardFocus(pid: pid_t, token: String) {
    guard AXIsProcessTrusted(),
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    else { return }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.08)
    var rawWindow: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &rawWindow)
      == .success, let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
    else { return }
    let window = unsafeDowncast(rawWindow, to: AXUIElement.self)
    AXUIElementSetMessagingTimeout(window, 0.08)
    var rawValues: CFArray?
    let attributes = [kAXPositionAttribute, kAXSizeAttribute, "AXFullScreen"]
    guard AXUIElementCopyMultipleAttributeValues(
      window, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &rawValues
    ) == .success, let values = rawValues as? [Any], values.count == attributes.count
    else { return }
    let position = values[0] as CFTypeRef
    let dimensions = values[1] as CFTypeRef
    var point = CGPoint.zero
    var size = CGSize.zero
    guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID(),
      AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
      AXValueGetValue(unsafeDowncast(dimensions, to: AXValue.self), .cgSize, &size),
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    else { return }
    var reply = ["pid": String(pid),
      "frame": [point.x, point.y, size.width, size.height].map { String(Double($0)) }.joined(separator: ",")]
    if let fullscreen = values[2] as? Bool { reply["fullscreen"] = fullscreen ? "1" : "0" }
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name("com.machinespirit.leader.focus.reply"), object: token,
      userInfo: reply, deliverImmediately: true)
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
    guard let screen = Defaults[.screen].getNSScreen() ?? NSScreen.main ?? NSScreen.screens.first
    else {
      Events.send(.didActivate)
      return
    }
    boardScreenFrame = screen.frame
    boardPanelShown = false
    userState.navigationPath = []
    userState.display = nil
    boardPanelShown = true
    window.updateOverlayAppearance()
    window.show(on: screen) {
      Events.send(.didActivate)
    }

    postBoardNavigation(hidden: false)

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
    exitHold()
    boardPanelShown = false
    postBoardNavigation(hidden: true)
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
    // A held arrow sends repeated key-downs without a second physical tap.
    if event.isARepeat && (KeyHelpers.leftArrow.rawValue...KeyHelpers.upArrow.rawValue).contains(event.keyCode) {
      return
    }
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

    if holdAction != nil {
      handleHoldKey(event)
      return
    }

    switch event.keyCode {
    case KeyHelpers.backspace.rawValue:
      // machine-spirit: ⌫ steps back ONE level (not a full clear); at the
      // root it stays open on the skull and just pulses it.
      if !userState.navigationPath.isEmpty {
        userState.navigationPath.removeLast()
        userState.display = userState.navigationPath.last?.key
      }
      postFeedback("back")
      delay(1) {
        self.positionCheatsheetWindow()
      }
    case KeyHelpers.escape.rawValue:
      // ⇪ ⎋ at the root: close, then un-capture the frontmost text field.
      if userState.navigationPath.isEmpty {
        hide {
          CommandRunner.run("[ -x ~/bin/blur-field.sh ] && ~/bin/blur-field.sh; true") { _ in }
        }
      } else {
        window.resignKey()
      }
    default:
      guard let char = charForEvent(event) else { return }
      handleKey(char, withModifiers: event.modifierFlags)
    }
  }

  func handleKey(
    _ key: String, withModifiers modifiers: NSEvent.ModifierFlags? = nil, execute: Bool = true
  ) {
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
        let path = userState.navigationPath.compactMap { $0.key } + [action.key ?? ""]
        let pathKey = path.joined(separator: "/")
        if action.quickRepeat == true, let hold = action.hold, let last = lastFired,
          last.key == pathKey, Date().timeIntervalSince(last.at) < 1.5
        {
          // Tapped again quickly: continue the hold ladder instead.
          let n = last.count + 1
          lastFired = (pathKey, Date(), n)
          hide { self.runHoldCommand(hold, n: n, key: action.key ?? "", path: pathKey) }
          return
        }
        lastFired = (pathKey, Date(), 1)
        if execute, Controller.leaderPhysicallyDown() {
          runAction(action)
          enterHold(action, path: path)
          return
        }
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
      postFeedback("miss")
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
      // The physical key is F19, so Caps Lock is only on when `⇪ c a p s`
      // (`ms capslock toggle`) turned it on for typing. Binds ignore it and
      // take case from Shift alone; otherwise `s s c` arrives as `S S C`.
      if event.modifierFlags.contains(.capsLock) && !event.modifierFlags.contains(.shift) {
        return printable.lowercased()
      }
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
    guard !UserDefaults.standard.bool(forKey: "msGraphOverlayEnabled") else { return }
    if !window.hasCheatsheet {
      return
    }
    positionCheatsheetWindow()
    cheatsheetWindow?.orderFront(nil)
  }

  private func scheduleCheatsheet() {
    cheatsheetTimer?.invalidate()
    guard !UserDefaults.standard.bool(forKey: "msGraphOverlayEnabled") else { return }

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
      let appURL = URL(fileURLWithPath: action.value)
      let wasRunning = NSWorkspace.shared.runningApplications.contains {
        $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL
      }
      NSWorkspace.shared.openApplication(
        at: appURL, configuration: NSWorkspace.OpenConfiguration()
      ) { app, _ in
        // Fresh launch: place its first window by the mouse (⇪ ␣ logic).
        guard !wasRunning, let name = app?.localizedName else { return }
        CommandRunner.run(
          "for i in $(seq 1 30); do ~/bin/ms win place smart --app \(name.shellQuoted) >/dev/null 2>&1 && break; sleep 0.1; done; true"
        ) { _ in }
      }
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

  // MARK: hold mode

  static func leaderPhysicallyDown() -> Bool {
    CGEventSource.keyState(.hidSystemState, key: leaderKeyCode)
  }

  private func enterHold(_ action: Action, path: [String]) {
    holdAction = action
    holdPath = path
    holdCount = 0
    holdSpaceCount = 0
    postNav(state: "hold", path: path.joined(separator: "/"))
    // The panel steps aside and a session event tap owns the keyboard while
    // ⇪ is held: it swallows only keys pressed during the hold, so the target
    // app keeps focus. (The first version re-took key every 50 ms whenever the
    // action activated its app — a visible focus tug-of-war.)
    if installHoldTap() { window?.orderOut(nil) }
    // Release detection backstop: a 50 ms keyState probe that exists ONLY
    // while holding (the tap also ends the hold on F19 key-up).
    holdWatch?.invalidate()
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      guard let self, self.holdAction != nil else { return }
      if !Controller.leaderPhysicallyDown() { self.hide() }
    }
    RunLoop.main.add(timer, forMode: .common)
    holdWatch = timer
  }

  private func installHoldTap() -> Bool {
    removeHoldTap()
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: { _, type, event, refcon in
          guard let refcon else { return Unmanaged.passUnretained(event) }
          let controller = Unmanaged<Controller>.fromOpaque(refcon).takeUnretainedValue()
          return controller.holdTapEvent(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
    else { return false }  // no Accessibility → keep the key-panel path
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    holdTap = tap
    holdTapSource = source
    return true
  }

  private func removeHoldTap() {
    if let tap = holdTap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    if let source = holdTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    holdTap = nil
    holdTapSource = nil
  }

  /// Runs on the main run loop. Swallows every key event while holding.
  private func holdTapEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap = holdTap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    guard holdAction != nil else { return Unmanaged.passUnretained(event) }
    let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    if code == Controller.leaderKeyCode {
      if type == .keyUp { DispatchQueue.main.async { self.hide() } }
      return nil  // F19 repeats/release never reach anything else
    }
    if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
      let ns = NSEvent(cgEvent: event)
    {
      DispatchQueue.main.async { self.handleHoldKey(ns) }
    }
    return nil
  }

  private func exitHold() {
    removeHoldTap()
    holdWatch?.invalidate()
    holdWatch = nil
    holdAction = nil
    holdPath = []
  }

  private func handleHoldKey(_ event: NSEvent) {
    guard let action = holdAction else { return }
    if event.keyCode == KeyHelpers.escape.rawValue {
      hide()
      return
    }
    guard let char = charForEvent(event) else { return }
    let isSpace = event.keyCode == KeyHelpers.space.rawValue
    let keyName = isSpace ? "space" : char
    let keys = action.holdKeys ?? action.key ?? ""
    let claimsKey = keys.contains(char) || (isSpace && keys.contains("space"))
    let pathKey = holdPath.joined(separator: "/")

    if let hold = action.hold, claimsKey {
      holdCount += 1
      postFeedback("hold", extra: ["n": String(holdCount), "key": keyName])
      runHoldCommand(hold, n: holdCount, key: keyName, path: pathKey)
    } else if isSpace {
      // Universal: ␣ after ANY action places the frontmost window by the
      // mouse (first press), then walks the grow ladder.
      holdSpaceCount += 1
      postFeedback("hold", extra: ["n": String(holdSpaceCount), "key": "space"])
      let mode = holdSpaceCount == 1 ? "smart" : "step"
      runHoldCommand("~/bin/ms win place \(mode)", n: holdSpaceCount, key: "space", path: pathKey)
    } else {
      // Any other key while ⇪ is held starts a fresh sequence from the root.
      exitHold()
      window?.makeKeyAndOrderFront(nil)
      userState.clear()
      postBoardNavigation(hidden: false)
      handleKey(char, withModifiers: event.modifierFlags)
    }
  }

  private func runHoldCommand(_ command: String, n: Int, key: String, path: String) {
    let env = "export MS_HOLD_N=\(n) MS_HOLD_KEY=\(key.shellQuoted) MS_HOLD_PATH=\(path.shellQuoted); "
    let input = CommandRunner.rectangleActionURL(for: command) == nil ? env + command : command
    CommandRunner.run(input) { [weak self] result in
      switch result.status {
      case 10: self?.postFeedback("done", path: path)
      case 11:
        self?.postFeedback("miss", path: path)
        if self?.window?.isVisible == true { self?.window.notFound() }
      default: break
      }
    }
  }

  private func postNav(state: String, path: String) {
    let frame = boardScreenFrame
    let screen = [frame.origin.x, frame.origin.y, frame.width, frame.height]
      .map { String(Int($0)) }.joined(separator: ",")
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name("com.machinespirit.leader.nav"), object: nil,
      userInfo: ["state": state, "path": path, "screen": screen], deliverImmediately: true)
  }

  /// UI feedback for the overlay: miss | back | done | hold.
  func postFeedback(_ kind: String, path: String? = nil, extra: [String: String] = [:]) {
    var info = extra
    info["kind"] = kind
    info["path"] = path ?? userState.navigationPath.compactMap { $0.key }.joined(separator: "/")
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name("com.machinespirit.leader.feedback"), object: nil,
      userInfo: info, deliverImmediately: true)
  }

  /// Cheap IPC: no app lookup, launch, URL open, or focus change on the bind path.
  private func fireBoardPing(actionKey: String?) {
    guard let actionKey else { return }
    let keys = userState.navigationPath.compactMap { $0.key } + [actionKey]
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name("com.machinespirit.leader.fired"), object: nil,
      userInfo: ["path": keys.joined(separator: "/")], deliverImmediately: true)
  }

  func postBoardNavigation(hidden: Bool) {
    guard hidden || (UserDefaults.standard.object(forKey: "msGraphOverlayEnabled") as? Bool ?? true)
    else { return }
    let frame = boardScreenFrame
    let screen = [frame.origin.x, frame.origin.y, frame.width, frame.height]
      .map { String(Int($0)) }.joined(separator: ",")
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name("com.machinespirit.leader.nav"), object: nil,
      userInfo: [
        "state": hidden ? "hidden" : "shown",
        "path": userState.navigationPath.compactMap { $0.key }.joined(separator: "/"),
        "screen": screen,
      ], deliverImmediately: true)
  }

  func overlayPreferenceChanged() {
    if UserDefaults.standard.bool(forKey: "msGraphOverlayEnabled") {
      cheatsheetTimer?.invalidate()
      cheatsheetWindow?.orderOut(nil)
    }
    window?.updateOverlayAppearance()
    postBoardNavigation(
      hidden: !boardPanelShown || !UserDefaults.standard.bool(forKey: "msGraphOverlayEnabled"))
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

extension String {
  /// Single-quoted for /bin/sh.
  var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
