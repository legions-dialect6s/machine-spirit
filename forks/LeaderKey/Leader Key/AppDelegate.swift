import Cocoa
import IOKit.hidsystem
import Defaults
import KeyboardShortcuts
import Settings
import SwiftUI
import os.log


@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate,
  NSWindowDelegate
{
  var controller: Controller!

  let statusItem = StatusItem()
  let clipboardHistory = ClipboardHistory()
  lazy var clipboardPanel = ClipboardPanel(history: clipboardHistory)
  private var previousFrontmost: NSRunningApplication?
  private var activationObserver: NSObjectProtocol?
  private var textFocusShortcutObserver: NSObjectProtocol?
  private var textFocusTap: CFMachPort?
  private var textFocusTapSource: CFRunLoopSource?
  private var pendingTextFocusPID: pid_t?
  private var gameForegroundPID: pid_t?
  let config = UserConfig()
  // machine-spirit fork: hot-reload — config edits land without a restart.
  let configMonitor = ConfigFileMonitor()

  var state: UserState!

  lazy var settingsWindowController = SettingsWindowController(
    panes: [
      Settings.Pane(
        identifier: .general, title: "General",
        toolbarIcon: NSImage(named: NSImage.preferencesGeneralName)!,
        contentView: { GeneralPane().environmentObject(self.config) }
      ),
      Settings.Pane(
        identifier: .advanced, title: "Advanced",
        toolbarIcon: NSImage(named: NSImage.advancedName)!,
        contentView: {
          AdvancedPane().environmentObject(self.config)
        }),
    ],
    style: .segmentedControl,
  )

  func applicationDidFinishLaunching(_: Notification) {

    guard
      ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
    else { return }
    guard !isRunningTests() else { return }
    // macOS can reopen a leftover XCTest host through Launch Services.
    // It must never register the daily driver’s hotkeys, menu item or power assertion.
    if Bundle.main.bundleIdentifier?.hasPrefix("com.machinespirit.testing.") == true {
      NSApp.terminate(nil)
      return
    }


    NSApp.mainMenu = MainMenu()

    SystemMenuSection.registerDefaults()
    config.ensureAndLoad()
    state = UserState(userConfig: config)
    controller = Controller(userState: state, userConfig: config)

    // machine-spirit fork: watch the config file and reload bindings on
    // change (debounced, rename-safe). The path closure re-reads the
    // current config location on every re-arm; the Defaults task below
    // re-watches when the config directory itself moves.
    configMonitor.watch(path: { self.config.path }) { [weak self] in
      self?.config.reloadFromFile()
    }
    Task {
      for await _ in Defaults.updates(.configDir, initial: false) {
        self.configMonitor.watch(path: { self.config.path }) { [weak self] in
          self?.config.reloadFromFile()
        }
      }
    }

    statusItem.handlePreferences = {
      self.showSettings()
    }
    statusItem.handleAbout = {
      NSApp.orderFrontStandardAboutPanel(nil)
    }
    statusItem.handleReloadConfig = {
      self.config.reloadFromFile()
    }
    statusItem.handleRevealConfig = {
      NSWorkspace.shared.activateFileViewerSelecting([self.config.url])
    }

    Task {
      // initial:false — the block below sets the initial state explicitly, so
      // this stream only needs to react to later toggles (no redundant double-init).
      for await value in Defaults.updates(.showMenuBarIcon, initial: false) {
        self.statusItem.setSkullVisible(value)
      }
    }

    statusItem.system.overlayChanged = { [weak self] in self?.controller?.overlayPreferenceChanged()
    }
    previousFrontmost = NSWorkspace.shared.frontmostApplication
    if let previousFrontmost { cacheGameForeground(previousFrontmost) }
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier
      else { return }
      self?.previousFrontmost = app
      self?.cacheGameForeground(app)
    }
    textFocusShortcutObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
    ) { [weak self] _ in self?.updateTextFocusTap() }
    clipboardHistory.start()
    statusItem.system.showClipboard = { [weak self] in self?.showClipboardHistory() }
    statusItem.system.clearClipboard = { [weak self] in self?.clipboardHistory.clearUnpinned() }
    statusItem.heartbeat = { [weak self] in self?.clipboardHistory.poll() }
    statusItem.enable()
    launchBoardIfNeeded()

    // Activation policy is managed solely by the Settings window

    registerGlobalShortcuts()
  }

  private func launchBoardIfNeeded() {
    let bundleID = "com.machinespirit.MachineSpirit"
    guard UserDefaults.standard.bool(forKey: "msLaunchBoardAtLogin"),
      !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }),
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
  }

  func activate() {
    // `controller` and its `window` are wired up during launch (the window is
    // even set asynchronously via the .theme observer). Ignore an activate that
    // arrives before they exist — e.g. a leaderkey:// URL delivered at launch —
    // rather than trapping on the implicitly-unwrapped optionals.
    guard let controller, let window = controller.window else { return }
    // Hold mode: ⇪ is already down; a repeat/second F19 press must not
    // hide or reset the session mid-hold.
    if controller.holdAction != nil { return }
    CapsLockGuard.clearIfStuck()

    if window.isKeyWindow {
      switch Defaults[.reactivateBehavior] {
      case .hide:
        self.hide()
      case .reset:
        controller.userState.clear()
      case .nothing:
        return
      }
    } else if window.isVisible {
      // should never happen as the window will self-hide when not key
      window.makeKeyAndOrderFront(nil)
    } else {
      self.show()
    }
  }

  public func registerGlobalShortcuts() {
    KeyboardShortcuts.removeAllHandlers()

    KeyboardShortcuts.onKeyDown(for: .activate) {
      self.activate()
    }

    KeyboardShortcuts.onKeyDown(for: .msClipboardHistory) { [weak self] in
      self?.showClipboardHistory()
    }

    KeyboardShortcuts.onKeyUp(for: .msReleaseTextFocus) { [weak self] in
      guard let self else { return }
      if self.usesDefaultTextFocusShortcut, self.textFocusTap != nil { return }
      guard let pid = self.textFocusTarget() else { return }
      if self.usesDefaultTextFocusShortcut, self.gameForegroundPID == pid { return }
      self.releaseTextFocusInForeground(pid: pid)
    }
    updateTextFocusTap()

    for groupKey in Defaults[.groupShortcuts] {
      print("Registering shortcut for \(groupKey)")
      KeyboardShortcuts.onKeyDown(for: KeyboardShortcuts.Name("group-\(groupKey)")) {
        if !self.controller.window.isVisible {
          self.activate()
        }
        self.processKeys([groupKey])
      }
    }
    if Defaults[.groupShortcuts].isEmpty && !KeyboardShortcuts.isEnabled(for: .activate) {
      showSettings()
    }
  }

  private var usesDefaultTextFocusShortcut: Bool {
    KeyboardShortcuts.getShortcut(for: .msReleaseTextFocus)
      == .init(.escape, modifiers: [.command])
  }

  private func cacheGameForeground(_ app: NSRunningApplication) {
    let gameHosts = ["com.apple.GameOverlayUI", "com.epicgames.EpicGamesLauncher", "com.valvesoftware.steam"]
    let category = app.bundleURL.flatMap { Bundle(url: $0) }?
      .object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
    let isGame = category == "public.app-category.games" || category?.hasSuffix("-games") == true
    gameForegroundPID = isGame || gameHosts.contains(app.bundleIdentifier ?? "") ? app.processIdentifier : nil
  }

  private func textFocusTarget() -> pid_t? {
    guard let current = NSWorkspace.shared.frontmostApplication else { return nil }
    if current.processIdentifier == getpid() {
      if NSApp.keyWindow != nil, NSApp.keyWindow === settingsWindowController.window { return nil }
      return previousFrontmost?.processIdentifier
    }
    return current.processIdentifier
  }

  private func updateTextFocusTap() {
    // Finish a consumed key pair before removing its tap.
    guard pendingTextFocusPID == nil else { return }
    guard usesDefaultTextFocusShortcut else { removeTextFocusTap(); return }
    guard textFocusTap == nil, AXIsProcessTrusted() else { return }
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    // Carbon can share this chord with macOS Game Overlay. Consume it before dispatch only
    // when it is still the configured shortcut and a non-game app has focus.
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
        return delegate.textFocusKeyEvent(type, event)
      }, userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else { return }
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    textFocusTap = tap
    textFocusTapSource = source
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  private func removeTextFocusTap() {
    if let tap = textFocusTap { CFMachPortInvalidate(tap) }
    if let source = textFocusTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    textFocusTap = nil
    textFocusTapSource = nil
  }

  private func textFocusKeyEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      pendingTextFocusPID = nil
      if let tap = textFocusTap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(KeyHelpers.escape.rawValue) else {
      return Unmanaged.passUnretained(event)
    }
    if let pid = pendingTextFocusPID {
      if type == .keyUp {
        pendingTextFocusPID = nil
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.updateTextFocusTap()
          if self.usesDefaultTextFocusShortcut { self.releaseTextFocusInForeground(pid: pid) }
        }
      }
      return nil
    }
    let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl, .maskSecondaryFn])
    guard type == .keyDown, modifiers == .maskCommand,
          event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
          KeyboardShortcuts.isEnabled, usesDefaultTextFocusShortcut,
          let pid = textFocusTarget(), pid != gameForegroundPID else {
      return Unmanaged.passUnretained(event)
    }
    pendingTextFocusPID = pid
    return nil
  }

  private func releaseTextFocusInForeground(pid: pid_t) {
    let release = {
      DispatchQueue.global(qos: .userInitiated).async {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              !releaseTextFocus(pid: pid) else { return }
        DispatchQueue.main.async {
          if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { NSSound.beep() }
        }
      }
    }
    if controller?.window?.isVisible == true { controller.hide(afterClose: release) }
    else { release() }
  }

  func showClipboardHistory() {
    let current = NSWorkspace.shared.frontmostApplication
    let target =
      current?.processIdentifier == ProcessInfo.processInfo.processIdentifier
      ? previousFrontmost : current
    controller?.hide { [weak self] in self?.clipboardPanel.show(previousApplication: target) }
  }

  func applicationWillTerminate(_ notification: Notification) {
    clipboardHistory.stop()
    if let activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
    }
    if let textFocusShortcutObserver { NotificationCenter.default.removeObserver(textFocusShortcutObserver) }
    removeTextFocusTap()
    statusItem.disable()
    controller?.postBoardNavigation(hidden: true)
    // Config saves automatically on changes
  }

  @IBAction
  func settingsMenuItemActionHandler(_: NSMenuItem) {
    showSettings()
  }

  func show() {
    controller?.show()
  }

  func hide() {
    controller?.hide()
  }

  func isRunningTests() -> Bool {
    let environment = ProcessInfo.processInfo.environment
    guard environment["XCTestSessionIdentifier"] != nil else { return false }
    return true
  }

  // MARK: - URL Scheme Handling

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      handleURL(url)
    }
  }

  private func handleURL(_ url: URL) {
    let action = URLSchemeHandler.parse(url)

    switch action {
    case .clipboard:
      showClipboardHistory()
    case .settings:
      showSettings()
    case .about:
      NSApp.orderFrontStandardAboutPanel(nil)
    case .configReload:
      config.reloadFromFile()
    case .configReveal:
      NSWorkspace.shared.selectFile(config.path, inFileViewerRootedAtPath: "")
    case .activate:
      activate()
    case .hide:
      hide()
    case .reset:
      state?.clear()
    case .navigate(let keys, let execute):
      show()
      processKeys(keys, execute: execute)
    case .show:
      show()
    case .invalid:
      return
    }
  }

  private func processKeys(_ keys: [String], execute: Bool = true) {
    // Require the theme window too (Controller sets it asynchronously):
    // handleKey's not-found branch derefs `window`, so a navigate URL that
    // races launch must be dropped rather than crash.
    guard let controller, controller.window != nil, !keys.isEmpty else { return }

    controller.handleKey(keys[0], execute: execute)

    if keys.count > 1 {
      let remainingKeys = Array(keys.dropFirst())

      var delayMs = 100
      for key in remainingKeys {
        delay(delayMs) { [weak self] in
          self?.controller?.handleKey(key, execute: execute)
        }
        delayMs += 100
      }
    }
  }

  // MARK: - Activation Policy: Only Settings Visibility Controls It

  private func showSettings() {
    // Behave like a normal app while Settings is open
    NSApp.setActivationPolicy(.regular)
    settingsWindowController.show()
    NSApp.activate(ignoringOtherApps: true)
    settingsWindowController.window?.delegate = self
  }

  // Revert to accessory when Settings window closes
  func windowWillClose(_ notification: Notification) {
    guard let win = notification.object as? NSWindow,
      win == settingsWindowController.window
    else { return }
    NSApp.setActivationPolicy(.accessory)
  }


}

/// Move keyboard focus within the active surface without sending a key or activating a control.
private func releaseTextFocus(pid: pid_t) -> Bool {
  let app = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(app, 0.08)
  let deadline = ProcessInfo.processInfo.systemUptime + 0.4
  func isFrontmost() -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
  }
  func canContinue() -> Bool {
    ProcessInfo.processInfo.systemUptime < deadline && isFrontmost()
  }
  func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
    return value
  }
  func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }
  func role(_ node: AXUIElement) -> String? {
    attribute(node, kAXRoleAttribute) as? String
  }

  let editors: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
  func isEditor(_ node: AXUIElement, _ kind: String) -> Bool {
    editors.contains(kind) || (attribute(node, "AXEditable") as? Bool == true)
  }
  guard canContinue() else { return false }
  // Chromium can initialize its native accessibility tree on a role request.
  _ = role(app)
  var focused = element(app, kAXFocusedUIElementAttribute)
  for _ in 0..<4 where focused == nil && canContinue() {
    Thread.sleep(forTimeInterval: 0.025)
    focused = element(app, kAXFocusedUIElementAttribute)
  }
  guard let editor = focused, let originalRole = role(editor) else { return false }
  guard isEditor(editor, originalRole) else { return true }

  func moveFocus(to candidate: AXUIElement) -> Bool {
    guard canContinue() else { return false }
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(candidate, kAXFocusedAttribute as CFString, &settable) == .success,
          settable.boolValue, canContinue(),
          let current = element(app, kAXFocusedUIElementAttribute), CFEqual(current, editor),
          canContinue() else { return false }
    // Some targets change first responder even when their AX setter returns an error.
    AXUIElementSetAttributeValue(candidate, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    for attempt in 0..<4 {
      guard isFrontmost() else { return false }
      if let focused = element(app, kAXFocusedUIElementAttribute), !CFEqual(focused, editor),
         let newRole = role(focused) {
        if !isEditor(focused, newRole), isFrontmost() { return true }
      }
      // Chromium can report the old focus until its renderer acknowledges the change.
      if attempt < 3, canContinue() { Thread.sleep(forTimeInterval: 0.015) }
      else { break }
    }
    return false
  }

  let containers: Set<String> = ["AXGroup", "AXScrollArea", "AXWebArea"]
  let destinations: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXLink",
                                    "AXPopUpButton", "AXHeading", "AXStaticText"]
  var branch = editor
  var remainingNodes = 48
  for _ in 0..<12 {
    guard canContinue(), let parent = element(branch, kAXParentAttribute),
          let kind = role(parent), kind != "AXApplication" else { break }
    if containers.contains(kind), !isEditor(parent, kind), moveFocus(to: parent) { return true }

    // Search nearby siblings first. Stop at the document, sheet, or window boundary.
    var level: [AXUIElement] = [parent]
    for _ in 0..<3 {
      var next: [AXUIElement] = []
      for container in level {
        guard canContinue(), remainingNodes > 0 else { return false }
        var children: CFArray?
        guard AXUIElementCopyAttributeValues(container, kAXChildrenAttribute as CFString,
                                               0, remainingNodes, &children) == .success,
              let candidates = children as? [AXUIElement] else { continue }
        for candidate in candidates where !CFEqual(candidate, branch) {
          guard canContinue(), remainingNodes > 0 else { return false }
          remainingNodes -= 1
          guard let candidateRole = role(candidate),
                containers.contains(candidateRole) || destinations.contains(candidateRole),
                !isEditor(candidate, candidateRole) else { continue }
          if moveFocus(to: candidate) { return true }
          if containers.contains(candidateRole), candidateRole != "AXWebArea" { next.append(candidate) }
        }
      }
      level = next
      if level.isEmpty { break }
    }
    if ["AXWebArea", "AXSheet", "AXWindow"].contains(kind) { break }
    branch = parent
  }
  return false
}

/// Caps Lock is remapped to F19 by Karabiner, so the physical key can never turn
/// the lock off again. If it gets latched on (e.g. while Karabiner restarts and
/// the raw key slips through), clear it whenever Leader Key is summoned.
enum CapsLockGuard {
  static func clearIfStuck() {
    guard NSEvent.modifierFlags.contains(.capsLock) else { return }
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
    guard service != 0 else { return }
    defer { IOObjectRelease(service) }
    var connect: io_connect_t = 0
    guard
      IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
        == KERN_SUCCESS
    else { return }
    defer { IOServiceClose(connect) }
    let status = IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
    os_log("Caps Lock was stuck on; cleared (status=%d)", status)
  }
}
