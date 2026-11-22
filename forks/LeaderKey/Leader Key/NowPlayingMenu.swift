import Cocoa

/// Thread-safe, host-only favicon fetcher and in-memory cache for audible browser tabs.
final class NowPlayingFaviconCache {
  static let shared = NowPlayingFaviconCache()
  private let cache = NSCache<NSString, NSImage>()
  private let lock = NSLock()
  private var inFlight: [String: [(NSImage?) -> Void]] = [:]
  private let session: URLSession

  init() {
    cache.countLimit = 128
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 3
    config.timeoutIntervalForResource = 5
    config.requestCachePolicy = .returnCacheDataElseLoad
    session = URLSession(configuration: config)
  }

  /// Strip credentials, path, query, and fragment so only public web hosts are queried.
  static func requestURL(for value: String) -> URL? {
    guard let site = URLComponents(string: value),
      ["http", "https"].contains(site.scheme?.lowercased() ?? ""),
      let host = site.host, !host.isEmpty
    else { return nil }
    var request = URLComponents()
    request.scheme = "https"
    request.host = "www.google.com"
    request.path = "/s2/favicons"
    request.queryItems = [
      URLQueryItem(name: "sz", value: "128"),
      URLQueryItem(name: "domain", value: host),
    ]
    return request.url
  }

  static func hostKey(for value: String) -> String? {
    guard let site = URLComponents(string: value),
      ["http", "https"].contains(site.scheme?.lowercased() ?? ""),
      let host = site.host, !host.isEmpty
    else { return nil }
    return host.lowercased()
  }

  func cachedIcon(for tabURL: String) -> NSImage? {
    guard let key = Self.hostKey(for: tabURL) else { return nil }
    return cache.object(forKey: key as NSString)
  }

  func fetchIcon(for tabURL: String, completion: @escaping (NSImage?) -> Void) {
    guard let key = Self.hostKey(for: tabURL),
      let requestURL = Self.requestURL(for: tabURL)
    else {
      completion(nil)
      return
    }
    if let cached = cache.object(forKey: key as NSString) {
      completion(cached)
      return
    }
    lock.lock()
    if inFlight[key] != nil {
      inFlight[key]?.append(completion)
      lock.unlock()
      return
    }
    inFlight[key] = [completion]
    lock.unlock()

    session.dataTask(with: requestURL) { [weak self] data, response, _ in
      var image: NSImage?
      if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
        let data, !data.isEmpty, let decoded = NSImage(data: data),
        decoded.size.width > 0, decoded.size.height > 0
      {
        image = decoded
      }
      guard let self else { return }
      if let image {
        self.cache.setObject(image, forKey: key as NSString)
      }
      self.lock.lock()
      let callbacks = self.inFlight.removeValue(forKey: key) ?? []
      self.lock.unlock()
      for callback in callbacks { callback(image) }
    }.resume()
  }
}

enum NowPlayingBrowserFocus {
  struct AudibleTab {
    let app: NSRunningApplication
    let pid: pid_t
    let title: String
    let rawTitle: String
    let url: String?
    let tabElement: AXUIElement
    let windowElement: AXUIElement
    let windowIndex: Int
    let tabIndex: Int
    let scriptWindowIndex: Int?
    let scriptTabIndex: Int?
  }

  struct ScriptTab: Equatable {
    let windowIndex: Int  // 1-based AppleScript window index
    let tabIndex: Int     // 1-based AppleScript tab index
    let title: String
    let url: String
  }

  private enum ScriptFlavor {
    case safari
    case chromium
  }

  private static let deniedLock = NSLock()
  private static var automationDenied = Set<String>()

  /// Ask Launch Services on click so a newly installed browser needs no app update.
  /// Being a web handler only qualifies the app for a bounded tab-strip inspection.
  static func isWebHandler(_ app: NSRunningApplication) -> Bool {
    guard let bundle = app.bundleURL?.resolvingSymlinksInPath() else { return false }
    let probe = URL(string: "https://example.invalid/")!
    return NSWorkspace.shared.urlsForApplications(toOpen: probe).contains {
      $0.resolvingSymlinksInPath() == bundle
    }
  }

  private static func scriptFlavor(for bundleIdentifier: String) -> ScriptFlavor? {
    switch bundleIdentifier {
    case "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.kagi.kagimacOS":
      return .safari
    case "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
      "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
      "company.thebrowser.Browser":
      return .chromium
    default:
      return nil
    }
  }

  /// Strip Chromium's accessibility metadata suffixes so menu rows show the clean page title.
  static func cleanTabTitle(_ raw: String) -> String {
    var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let cutMarkers = [
      " - Memory usage - ",
      " - Inactive tab - ",
      " - Part of group ",
    ]
    for marker in cutMarkers {
      if let range = title.range(of: marker) {
        title = String(title[..<range.lowerBound])
      }
    }
    let trailingSuffixes = [
      " - Audio playing",
      " - Tab muted",
      " - Audio muted",
    ]
    var changed = true
    while changed {
      changed = false
      for suffix in trailingSuffixes where title.hasSuffix(suffix) {
        title = String(title.dropLast(suffix.count))
        changed = true
      }
    }
    return title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func matchScriptTab(
    axTitle: String, windowIndex: Int, tabIndex: Int, scriptTabs: [ScriptTab]
  ) -> ScriptTab? {
    let cleaned = cleanTabTitle(axTitle)
    func titleMatches(_ candidate: String) -> Bool {
      candidate == axTitle || candidate == cleaned
        || axTitle.hasPrefix(candidate + " - ")
        || cleaned.hasPrefix(candidate + " - ")
    }
    if let direct = scriptTabs.first(where: {
      $0.windowIndex == windowIndex + 1 && $0.tabIndex == tabIndex + 1 && titleMatches($0.title)
    }) {
      return direct
    }
    let exact = scriptTabs.filter { $0.title == axTitle || $0.title == cleaned }
    if let sameTab = exact.first(where: { $0.tabIndex == tabIndex + 1 }) { return sameTab }
    if let first = exact.first { return first }
    let prefixed = scriptTabs.filter {
      !$0.title.isEmpty && (axTitle.hasPrefix($0.title + " - ") || cleaned.hasPrefix($0.title + " - "))
    }
    return prefixed.max(by: { $0.title.count < $1.title.count })
  }

  static func scriptTabs(for bundleIdentifier: String) -> [ScriptTab]? {
    guard let flavor = scriptFlavor(for: bundleIdentifier) else { return nil }
    deniedLock.lock()
    let denied = automationDenied.contains(bundleIdentifier)
    deniedLock.unlock()
    if denied { return nil }

    let titleProp = flavor == .safari ? "name" : "title"
    let escapedBundle = bundleIdentifier.replacingOccurrences(of: "\"", with: "\\\"")
    let source = """
      tell application id "\(escapedBundle)"
        if not running then return {{}, {}}
        return {\(titleProp) of every tab of every window, URL of every tab of every window}
      end tell
      """
    guard let script = NSAppleScript(source: source) else { return nil }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error {
      if let number = error[NSAppleScript.errorNumber] as? Int, number == -1743 {
        deniedLock.lock()
        automationDenied.insert(bundleIdentifier)
        deniedLock.unlock()
      }
      return nil
    }
    guard result.numberOfItems == 2,
      let titlesByWindow = result.atIndex(1),
      let urlsByWindow = result.atIndex(2)
    else { return nil }
    let windowCount = min(titlesByWindow.numberOfItems, urlsByWindow.numberOfItems)
    var tabs: [ScriptTab] = []
    guard windowCount > 0 else { return [] }
    for wi in 1...windowCount {
      guard let wTitles = titlesByWindow.atIndex(wi), let wURLs = urlsByWindow.atIndex(wi) else {
        continue
      }
      let tabCount = min(wTitles.numberOfItems, wURLs.numberOfItems)
      guard tabCount > 0 else { continue }
      for ti in 1...tabCount {
        let title = wTitles.atIndex(ti)?.stringValue ?? ""
        let url = wURLs.atIndex(ti)?.stringValue ?? ""
        tabs.append(ScriptTab(windowIndex: wi, tabIndex: ti, title: title, url: url))
      }
    }
    return tabs
  }

  private struct RawAXTab {
    let tab: AXUIElement
    let window: AXUIElement
    let windowIndex: Int
    let tabIndex: Int
    let rawTitle: String
    let hasMuteControl: Bool
    let hasTitleAudioHint: Bool
  }

  // Safari removes the speaker from narrow tabs. Its toolbar sound menu still
  // lists each audible page. Read this once before our own menu begins tracking.
  static func safariSoundTitles() -> Set<String> {
    guard AXIsProcessTrusted(),
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first
    else { return [] }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.1)
    let deadline = ProcessInfo.processInfo.systemUptime + 0.25
    func soundButton(_ element: AXUIElement) -> AXUIElement? {
      guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
      AXUIElementSetMessagingTimeout(element, 0.05)
      let role: String? = try? attribute(element, kAXRoleAttribute)
      if role == kAXButtonRole {
        let label: String? = try? attribute(element, kAXDescriptionAttribute)
        if ["Mute All Tabs", "Mute This Tab", "Mute Other Tabs"].contains(label ?? "") { return element }
      }
      guard [kAXToolbarRole, kAXGroupRole, kAXButtonRole].contains(role ?? "") else { return nil }
      for child in (try? attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
        if let button = soundButton(child) { return button }
      }
      return nil
    }
    let windows = (try? attribute(root, kAXWindowsAttribute) as [AXUIElement]?) ?? []
    for window in windows {
      let children = (try? attribute(window, kAXChildrenAttribute) as [AXUIElement]?) ?? []
      for toolbar in children where (try? attribute(toolbar, kAXRoleAttribute) as String?) == kAXToolbarRole {
        guard let button = soundButton(toolbar) else { continue }
        return titlesInSoundMenu(button, root: root, pid: app.processIdentifier)
      }
    }
    return []
  }

  private static func titlesInSoundMenu(_ button: AXUIElement, root: AXUIElement, pid: pid_t) -> Set<String> {
    func popup() -> CGRect? {
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0)
        as? [[String: Any]] ?? []
      for window in windows where window[kCGWindowOwnerPID as String] as? Int32 == pid &&
        window[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.popUpMenuWindow)) {
        if let rect = window[kCGWindowBounds as String] as? [String: Any] {
          return CGRect(dictionaryRepresentation: rect as CFDictionary)
        }
      }
      return nil
    }
    guard popup() == nil, AXUIElementPerformAction(button, kAXShowMenuAction as CFString) == .success
    else { return [] }
    for _ in 0..<8 {
      if let rect = popup() {
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(root, Float(rect.minX + 12), Float(rect.minY + 12), &hit)
        if let hit {
          let role: String? = try? attribute(hit, kAXRoleAttribute)
          let menu: AXUIElement? = role == kAXMenuRole ? hit : try? attribute(hit, kAXParentAttribute)
          if let menu, (try? attribute(menu, kAXRoleAttribute) as String?) == kAXMenuRole {
            defer { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
            let entries = (try? attribute(menu, kAXChildrenAttribute) as [AXUIElement]?) ?? []
            let names = entries.map { (try? attribute($0, kAXTitleAttribute) as String?) ?? "" }
            return soundTitles(from: names)
          }
        }
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return []
  }

  static func soundTitles(from entries: [String]) -> Set<String> {
    guard let header = entries.firstIndex(where: { $0 == "Tab With Sound" || $0 == "Tabs With Sound" })
    else { return [] }
    return Set(entries.dropFirst(header + 1).prefix(while: { !$0.isEmpty }))
  }

  private static func scanAXTabs(in root: AXUIElement, soundTitles: Set<String> = []) -> [RawAXTab] {
    let deadline = ProcessInfo.processInfo.systemUptime + 0.5
    var remaining = 4096
    var found: [RawAXTab] = []
    var candidates: [RawAXTab] = []
    do {
      func prepare(_ element: AXUIElement) throws {
        let secondsLeft = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, secondsLeft > 0 else { throw ScanError.incomplete }
        remaining -= 1
        AXUIElementSetMessagingTimeout(element, Float(min(0.05, secondsLeft)))
      }
      func hasAudioControl(_ tab: AXUIElement) throws -> Bool {
        for child in try attribute(tab, kAXChildrenAttribute) as [AXUIElement]? ?? [] {
          try prepare(child)
          let role: String? = try attribute(child, kAXRoleAttribute)
          guard role == kAXButtonRole || role == kAXImageRole else { continue }
          let title: String? = try attribute(child, kAXTitleAttribute)
          let description: String? = try attribute(child, kAXDescriptionAttribute)
          if title?.caseInsensitiveCompare("Mute tab") == .orderedSame
            || description?.caseInsensitiveCompare("Mute tab") == .orderedSame
            || description?.caseInsensitiveCompare("Audio playing") == .orderedSame
            || description?.caseInsensitiveCompare("Playing audio") == .orderedSame
          {
            return true
          }
        }
        return false
      }
      func inspect(
        _ element: AXUIElement, window: AXUIElement, windowIndex: Int, inTabStrip: Bool,
        tabCounter: inout Int
      ) throws {
        try prepare(element)
        let role: String? = try attribute(element, kAXRoleAttribute)
        switch role {
        case "AXOpaqueProviderGroup":
          // Safari exposes its tab bar as an opaque list beside the document.
          let identifier: String? = try attribute(element, kAXIdentifierAttribute)
          guard identifier?.hasPrefix("TabBar?") == true else { return }
          for child in try attribute(element, kAXChildrenAttribute) as [AXUIElement]? ?? [] {
            try inspect(
              child, window: window, windowIndex: windowIndex, inTabStrip: true,
              tabCounter: &tabCounter)
          }
        case kAXTabGroupRole, kAXGroupRole, kAXWindowRole, kAXSplitGroupRole, kAXScrollAreaRole,
          kAXToolbarRole:
          let isTabStrip = inTabStrip || role == kAXTabGroupRole
          for child in try attribute(element, kAXChildrenAttribute) as [AXUIElement]? ?? [] {
            try inspect(
              child, window: window, windowIndex: windowIndex, inTabStrip: isTabStrip,
              tabCounter: &tabCounter)
          }
        case kAXRadioButtonRole where inTabStrip:
          guard try attribute(element, kAXSubroleAttribute) as String? == "AXTabButton" else {
            return
          }
          let tabIndex = tabCounter
          tabCounter += 1
          let title = (try? attribute(element, kAXTitleAttribute) as String?) ?? ""
          let desc = (try? attribute(element, kAXDescriptionAttribute) as String?) ?? ""
          let rawTitle = title.isEmpty ? desc : title
          let muteControl = try hasAudioControl(element)
          let titleAudioHint =
            title.contains(" - Audio playing") || desc.contains(" - Audio playing")
          let candidate = RawAXTab(
            tab: element, window: window, windowIndex: windowIndex, tabIndex: tabIndex,
            rawTitle: rawTitle, hasMuteControl: muteControl, hasTitleAudioHint: titleAudioHint)
          if muteControl || titleAudioHint {
            found.append(candidate)
          } else if soundTitles.contains(rawTitle) {
            candidates.append(candidate)
          }
        default:
          break
        }
      }
      try prepare(root)
      let role: String? = try attribute(root, kAXRoleAttribute)
      let windows: [AXUIElement] =
        role == kAXWindowRole ? [root] : try attribute(root, kAXWindowsAttribute) ?? []
      for (windowIndex, window) in windows.enumerated() {
        var tabCounter = 0
        try inspect(
          window, window: window, windowIndex: windowIndex, inTabStrip: false,
          tabCounter: &tabCounter)
        if tabCounter == 0, let title: String = try attribute(window, kAXTitleAttribute),
          soundTitles.contains(title) {
          candidates.append(RawAXTab(tab: window, window: window, windowIndex: windowIndex, tabIndex: 0,
            rawTitle: title, hasMuteControl: false, hasTitleAudioHint: false))
        }
      }
      found += candidates.filter { candidate in candidates.lazy.filter { $0.rawTitle == candidate.rawTitle }.count == 1 }
    } catch {
      // Return whatever audible tabs were discovered before timeout/incomplete error.
    }
    return found
  }

  static func audibleTabs(in app: NSRunningApplication, includeURLs: Bool = true, soundTitles: Set<String> = []) -> [AudibleTab] {
    guard !app.isTerminated, AXIsProcessTrusted() else { return [] }
    let pid = app.processIdentifier
    let rawTabs = scanAXTabs(in: AXUIElementCreateApplication(pid), soundTitles: soundTitles)
    guard !rawTabs.isEmpty else { return [] }
    let scriptList: [ScriptTab] =
      includeURLs ? (app.bundleIdentifier.flatMap { scriptTabs(for: $0) } ?? []) : []
    return rawTabs.map { raw in
      let matched = matchScriptTab(
        axTitle: raw.rawTitle, windowIndex: raw.windowIndex, tabIndex: raw.tabIndex,
        scriptTabs: scriptList)
      let cleanTitle =
        (matched?.title.isEmpty == false ? matched!.title : cleanTabTitle(raw.rawTitle))
      let displayTitle = cleanTitle.isEmpty ? (app.localizedName ?? "Browser tab") : cleanTitle
      return AudibleTab(
        app: app, pid: pid, title: displayTitle, rawTitle: raw.rawTitle,
        url: matched?.url.isEmpty == false ? matched?.url : nil,
        tabElement: raw.tab, windowElement: raw.window,
        windowIndex: raw.windowIndex, tabIndex: raw.tabIndex,
        scriptWindowIndex: matched?.windowIndex, scriptTabIndex: matched?.tabIndex)
    }
  }

  /// Focus the exact audible browser tab and raise its window in a single click.
  @discardableResult
  static func focus(tab: AudibleTab) -> Bool {
    guard !tab.app.isTerminated else { return false }
    var targetTab = tab.tabElement
    var targetWindow = tab.windowElement

    // Re-resolve via AX if the cached element went stale while the menu was open.
    AXUIElementSetMessagingTimeout(targetTab, 0.2)
    AXUIElementSetMessagingTimeout(targetWindow, 0.2)
    if (try? attribute(targetTab, kAXRoleAttribute) as String?) == nil {
      let fresh = scanAXTabs(in: AXUIElementCreateApplication(tab.pid), soundTitles: [tab.rawTitle])
      if let replacement = fresh.first(where: { $0.rawTitle == tab.rawTitle })
        ?? fresh.first(where: { cleanTabTitle($0.rawTitle) == tab.title })
      {
        targetTab = replacement.tab
        targetWindow = replacement.window
      }
    }

    // 1. Unminimize target window if minimized.
    if (try? attribute(targetWindow, kAXMinimizedAttribute) as NSNumber?)?.boolValue == true {
      AXUIElementSetAttributeValue(targetWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    // 2. Select the audible tab and raise its owning window BEFORE/WITH app activation.
    let pressed = AXUIElementPerformAction(targetTab, kAXPressAction as CFString) == .success
    AXUIElementSetAttributeValue(targetWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
    let raised = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString) == .success

    // 3. For multi-window Safari/Chromium or if AX press failed (e.g. overflow tab bar),
    // also ask the browser via AppleScript to switch the tab and promote its window to index 1.
    var scriptFocused = false
    if let bundleID = tab.app.bundleIdentifier,
      (tab.scriptTabIndex != nil || !pressed || tab.windowIndex > 0 || !raised)
    {
      scriptFocused = focusViaAppleScript(
        bundleIdentifier: bundleID, windowIndex: tab.scriptWindowIndex,
        tabIndex: tab.scriptTabIndex, title: tab.title, url: tab.url)
    }

    // 4. Activate the browser ignoring other apps so WindowServer switches immediately.
    DispatchQueue.main.async {
      if !tab.app.isTerminated {
        tab.app.activate(options: [.activateIgnoringOtherApps])
      }
    }

    // 5. Confirmation pass after activation settles: prevent WindowServer from re-raising
    // the browser's previous frontmost window above the target window.
    let pid = tab.pid
    let app = tab.app
    let confirmTab = targetTab
    let confirmWindow = targetWindow
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.08) {
      guard !app.isTerminated,
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
      else { return }
      AXUIElementSetMessagingTimeout(confirmWindow, 0.1)
      AXUIElementSetMessagingTimeout(confirmTab, 0.1)
      AXUIElementSetAttributeValue(confirmWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
      AXUIElementPerformAction(confirmWindow, kAXRaiseAction as CFString)
      if (try? attribute(confirmTab, kAXValueAttribute) as NSNumber?)?.intValue != 1 {
        AXUIElementPerformAction(confirmTab, kAXPressAction as CFString)
      }
    }

    return pressed || scriptFocused
  }

  private static func focusViaAppleScript(
    bundleIdentifier: String, windowIndex: Int?, tabIndex: Int?, title: String, url: String?
  ) -> Bool {
    guard let flavor = scriptFlavor(for: bundleIdentifier) else { return false }
    deniedLock.lock()
    let denied = automationDenied.contains(bundleIdentifier)
    deniedLock.unlock()
    if denied { return false }

    func escape(_ s: String) -> String {
      s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    let escapedBundle = escape(bundleIdentifier)
    let escapedURL = url.map(escape) ?? ""
    let escapedTitle = escape(title)
    let wi = windowIndex ?? 0
    let ti = tabIndex ?? 0

    let source: String
    switch flavor {
    case .safari:
      source = """
        tell application id "\(escapedBundle)"
          set targetWin to missing value
          set targetTab to missing value
          if \(wi) > 0 and \(ti) > 0 and (count of windows) >= \(wi) then
            set candidateWin to window \(wi)
            if (count of tabs of candidateWin) >= \(ti) then
              set candidateTab to tab \(ti) of candidateWin
              if ("\(escapedURL)" is "" or URL of candidateTab is "\(escapedURL)") and ("\(escapedTitle)" is "" or name of candidateTab is "\(escapedTitle)") then
                set targetWin to candidateWin
                set targetTab to candidateTab
              end if
            end if
          end if
          if targetTab is missing value then
            repeat with w in windows
              repeat with t in tabs of w
                if ("\(escapedURL)" is not "" and URL of t is "\(escapedURL)") or ("\(escapedTitle)" is not "" and name of t is "\(escapedTitle)") then
                  set targetWin to w
                  set targetTab to t
                  exit repeat
                end if
              end repeat
              if targetTab is not missing value then exit repeat
            end repeat
          end if
          if targetTab is missing value then return false
          set current tab of targetWin to targetTab
          set index of targetWin to 1
          activate
          return true
        end tell
        """
    case .chromium:
      source = """
        tell application id "\(escapedBundle)"
          set targetWin to missing value
          set targetIdx to 0
          if \(wi) > 0 and \(ti) > 0 and (count of windows) >= \(wi) then
            set candidateWin to window \(wi)
            if (count of tabs of candidateWin) >= \(ti) then
              set candidateTab to tab \(ti) of candidateWin
              if ("\(escapedURL)" is "" or URL of candidateTab is "\(escapedURL)") and ("\(escapedTitle)" is "" or title of candidateTab is "\(escapedTitle)") then
                set targetWin to candidateWin
                set targetIdx to \(ti)
              end if
            end if
          end if
          if targetIdx is 0 then
            repeat with w in windows
              set idx to 0
              repeat with t in tabs of w
                set idx to idx + 1
                if ("\(escapedURL)" is not "" and URL of t is "\(escapedURL)") or ("\(escapedTitle)" is not "" and title of t is "\(escapedTitle)") then
                  set targetWin to w
                  set targetIdx to idx
                  exit repeat
                end if
              end repeat
              if targetIdx > 0 then exit repeat
            end repeat
          end if
          if targetIdx is 0 then return false
          set active tab index of targetWin to targetIdx
          set index of targetWin to 1
          activate
          return true
        end tell
        """
    }
    guard let script = NSAppleScript(source: source) else { return false }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error {
      if let number = error[NSAppleScript.errorNumber] as? Int, number == -1743 {
        deniedLock.lock()
        automationDenied.insert(bundleIdentifier)
        deniedLock.unlock()
      }
      return false
    }
    return result.booleanValue
  }

  /// Safari and Chromium expose a native "Mute tab" button under audible tabs.
  /// Inspect only browser chrome and leave the current selection on ambiguity.
  static func focusAudibleTab(in root: AXUIElement, shouldFocus: () -> Bool) -> Bool {
    let tabs = scanAXTabs(in: root)
    guard tabs.count == 1, let match = tabs.first else { return false }
    guard shouldFocus() else { return false }
    if (try? attribute(match.window, kAXMinimizedAttribute) as NSNumber?)?.boolValue == true {
      AXUIElementSetAttributeValue(match.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    guard AXUIElementPerformAction(match.tab, kAXPressAction as CFString) == .success else {
      return false
    }
    if shouldFocus() {
      AXUIElementSetAttributeValue(match.window, kAXMainAttribute as CFString, kCFBooleanTrue)
      AXUIElementPerformAction(match.window, kAXRaiseAction as CFString)
    }
    return true
  }

  private enum ScanError: Error { case incomplete, ambiguous }

  private static func attribute<T>(_ element: AXUIElement, _ name: String) throws -> T? {
    var value: CFTypeRef?
    switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
    case .success: return value as? T
    case .noValue, .attributeUnsupported: return nil
    default: throw ScanError.incomplete
    }
  }
}

private final class NowPlayingTarget: NSObject {
  let app: NSRunningApplication
  let tab: NowPlayingBrowserFocus.AudibleTab?
  init(app: NSRunningApplication, tab: NowPlayingBrowserFocus.AudibleTab?) {
    self.app = app
    self.tab = tab
  }
}

final class NowPlayingMenuSection: NSObject {
  struct AppRow {
    let app: NSRunningApplication?
    let pid: pid_t
    let name: String
    var levels: [NowPlayingLevel]
    var icon: NSImage? = nil
    var url: String? = nil
    var tab: NowPlayingBrowserFocus.AudibleTab? = nil
    var tooltip: String? = nil
    var isFavicon: Bool = false

    var key: String {
      if let tab {
        return "\(pid):tab:\(tab.windowIndex):\(tab.tabIndex):\(name):\(!levels.isEmpty)"
      }
      return "\(pid):\(name):\(!levels.isEmpty)"
    }
  }
  private weak var menu: NSMenu?
  private var items: [NSMenuItem] = []
  private var rowViews: [NowPlayingRowView] = []
  private let queue = DispatchQueue(label: "com.machinespirit.now-playing", qos: .utility)
  private let browserFocusQueue = DispatchQueue(
    label: "com.machinespirit.now-playing.browser-focus", qos: .userInitiated)
  private let capturePolicy = NowPlayingCapturePolicy()
  private var session: NowPlayingAudioSession?
  private var processTimer: Timer?
  private var meterTimer: Timer?
  private var generation = 0
  private var sampling = false
  private var lastSnapshot: NowPlayingAudioSession.Snapshot?
  private var browserTabs: [pid_t: [NowPlayingBrowserFocus.AudibleTab]] = [:]
  private var browserScanInFlight = Set<pid_t>()
  private var safariTitles = Set<String>()
  private var knownTabURLs: [String: String] = [:]
  private(set) var rows: [AppRow] = []
  private(set) var isOpen = false
  private(set) var sampleCount = 0
  private(set) var metersUnavailable = false
  private(set) var enumerationFailed = false
  private var lastRowKeys: [String] = []
  // Injection is also used by the standalone smoke harness for deterministic
  // denial and close-during-enumeration tests. Production uses CoreAudio.
  var enumerate: () throws -> [NowPlayingProcess] = nowPlayingProcesses
  var makeTap: NowPlayingAudioSession.TapFactory?

  func append(to menu: NSMenu) {
    self.menu = menu
    items.removeAll()
    rowViews.removeAll()
    lastRowKeys.removeAll()
    let item = NSMenuItem(title: "Checking audio…", action: nil, keyEquivalent: "")
    item.isEnabled = false
    menu.addItem(item)
    items = [item]
  }

  func prepareForMenu() {
    safariTitles = NowPlayingBrowserFocus.safariSoundTitles()
  }

  func open() {
    precondition(Thread.isMainThread)
    guard !isOpen else { return }
    guard #available(macOS 14.4, *) else {
      items.first?.title = "Requires macOS 14.4"
      return
    }
    isOpen = true
    generation += 1
    browserTabs.removeAll()
    browserScanInFlight.removeAll()
    lastSnapshot = nil
    session = NowPlayingAudioSession(
      queue: queue, policy: capturePolicy, enumerate: enumerate, makeTap: makeTap)
    sample()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
    timer.tolerance = 0.1
    processTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func sample() {
    guard isOpen, !sampling, let session else { return }
    sampling = true
    let current = generation
    session.sample { [weak self] snapshot in
      // Explicit common-mode delivery works even inside NSMenu tracking.
      RunLoop.main.perform(inModes: [.common]) { [weak self] in
        guard let self, self.isOpen, self.generation == current else { return }
        self.sampling = false
        self.sampleCount += 1
        self.apply(snapshot)
      }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
  }

  private func refreshBrowserTabs(for app: NSRunningApplication, generation current: Int) {
    let pid = app.processIdentifier
    guard !browserScanInFlight.contains(pid), AXIsProcessTrusted() else { return }
    browserScanInFlight.insert(pid)
    let cachedURLs = knownTabURLs
    let titles = app.bundleIdentifier == "com.apple.Safari" ? safariTitles : []
    browserFocusQueue.async { [weak self] in
      // Fast stage: AX scan (~20ms) gives tab titles immediately so the row never lingers as "Safari".
      let fastTabs = NowPlayingBrowserFocus.audibleTabs(in: app, includeURLs: false, soundTitles: titles)
      let fastEnriched = fastTabs.map { tab -> NowPlayingBrowserFocus.AudibleTab in
        guard tab.url == nil, let hint = cachedURLs["\(pid):\(tab.rawTitle)"] else { return tab }
        return NowPlayingBrowserFocus.AudibleTab(
          app: tab.app, pid: tab.pid, title: tab.title, rawTitle: tab.rawTitle, url: hint,
          tabElement: tab.tabElement, windowElement: tab.windowElement,
          windowIndex: tab.windowIndex, tabIndex: tab.tabIndex,
          scriptWindowIndex: tab.scriptWindowIndex, scriptTabIndex: tab.scriptTabIndex)
      }
      RunLoop.main.perform(inModes: [.common]) { [weak self] in
        guard let self, self.isOpen, self.generation == current else { return }
        if !fastEnriched.isEmpty {
          self.browserTabs[pid] = fastEnriched
          if let snapshot = self.lastSnapshot { self.rebuildRows(from: snapshot) }
        }
      }
      CFRunLoopWakeUp(CFRunLoopGetMain())

      // Full stage: resolve exact tab URLs + AppleScript indices for website favicons and 1-click focus.
      let fullTabs =
        fastTabs.isEmpty ? [] : NowPlayingBrowserFocus.audibleTabs(in: app, includeURLs: true, soundTitles: titles)
      RunLoop.main.perform(inModes: [.common]) { [weak self] in
        guard let self, self.isOpen, self.generation == current else { return }
        self.browserScanInFlight.remove(pid)
        self.browserTabs[pid] = fullTabs.isEmpty ? fastEnriched : fullTabs
        for tab in fullTabs {
          if let url = tab.url { self.knownTabURLs["\(pid):\(tab.rawTitle)"] = url }
        }
        if let snapshot = self.lastSnapshot { self.rebuildRows(from: snapshot) }
      }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
  }

  private func apply(_ snapshot: NowPlayingAudioSession.Snapshot) {
    lastSnapshot = snapshot
    let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    var activeBrowserPIDs = Set<pid_t>()
    for process in snapshot.processes {
      if let app = nowPlayingOwner(
        NSRunningApplication(processIdentifier: process.pid), regular: regular),
        NowPlayingBrowserFocus.isWebHandler(app)
      {
        activeBrowserPIDs.insert(app.processIdentifier)
        refreshBrowserTabs(for: app, generation: generation)
      }
    }
    browserTabs = browserTabs.filter { activeBrowserPIDs.contains($0.key) }
    rebuildRows(from: snapshot)
  }

  private func rebuildRows(from snapshot: NowPlayingAudioSession.Snapshot) {
    let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    struct GroupedApp {
      let app: NSRunningApplication?
      let pid: pid_t
      let name: String
      var levels: [NowPlayingLevel]
    }
    var grouped: [pid_t: GroupedApp] = [:]
    for process in snapshot.processes {
      let app = nowPlayingOwner(
        NSRunningApplication(processIdentifier: process.pid), regular: regular)
      let pid = app?.processIdentifier ?? process.pid
      var entry =
        grouped[pid]
        ?? GroupedApp(app: app, pid: pid, name: app?.localizedName ?? "Process \(pid)", levels: [])
      if let level = snapshot.levels[process.object] { entry.levels.append(level) }
      grouped[pid] = entry
    }

    var built: [AppRow] = []
    let sortedGroups = grouped.values.sorted {
      let order = $0.name.localizedCaseInsensitiveCompare($1.name)
      return order == .orderedSame ? $0.pid < $1.pid : order == .orderedAscending
    }
    for group in sortedGroups {
      if let app = group.app, let tabs = browserTabs[group.pid], !tabs.isEmpty {
        for tab in tabs {
          let cached = tab.url.flatMap { NowPlayingFaviconCache.shared.cachedIcon(for: $0) }
          let host = tab.url.flatMap { NowPlayingFaviconCache.hostKey(for: $0) }
          let browserName = app.localizedName ?? group.name
          let tip =
            host.map { "\(browserName) — \(tab.title) (\($0))" } ?? "\(browserName) — \(tab.title)"
          built.append(
            AppRow(
              app: app, pid: group.pid, name: tab.title, levels: group.levels,
              icon: cached ?? app.icon, url: tab.url, tab: tab, tooltip: tip,
              isFavicon: cached != nil))
        }
      } else {
        built.append(
          AppRow(
            app: group.app, pid: group.pid, name: group.name, levels: group.levels,
            icon: group.app?.icon))
      }
    }

    rows = built
    metersUnavailable = snapshot.metersUnavailable
    enumerationFailed = snapshot.enumerationFailed
    renderRows()
    fetchMissingFavicons()
    if rows.contains(where: { !$0.levels.isEmpty }) {
      if meterTimer == nil {
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
          self?.redrawMeters()
        }
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
      }
      redrawMeters()
    } else {
      meterTimer?.invalidate()
      meterTimer = nil
    }
  }

  private func fetchMissingFavicons() {
    let current = generation
    for (index, row) in rows.enumerated() {
      guard !row.isFavicon, let url = row.url else { continue }
      let rowKey = row.key
      NowPlayingFaviconCache.shared.fetchIcon(for: url) { [weak self] image in
        guard let image else { return }
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
          guard let self, self.isOpen, self.generation == current,
            index < self.rows.count, index < self.rowViews.count,
            self.rows[index].key == rowKey
          else { return }
          self.rows[index].icon = image
          self.rows[index].isFavicon = true
          self.rowViews[index].updateIcon(image, rounded: true)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
      }
    }
  }

  private func renderRows() {
    guard let menu else { return }
    // Keep the menu items stable while tracking unless membership changes.
    let keys =
      rows.map(\.key) + [
        "\(metersUnavailable):\(enumerationFailed)"
      ]
    if keys == lastRowKeys {
      for (index, row) in rows.enumerated() {
        rowViews[index].levels = row.levels
        rowViews[index].updateIcon(row.icon, rounded: row.isFavicon)
        rowViews[index].toolTip = row.tooltip
        items[index].representedObject = row.app.map { NowPlayingTarget(app: $0, tab: row.tab) }
        items[index].isEnabled = row.app != nil
      }
      return
    }
    guard let first = items.first, first.menu === menu else { return }
    let insertionIndex = menu.index(of: first)
    lastRowKeys = keys
    for item in items where item.menu === menu { menu.removeItem(item) }
    items.removeAll()
    rowViews.removeAll()
    for row in rows {
      let item = NSMenuItem(title: row.name, action: #selector(activate(_:)), keyEquivalent: "")
      item.target = self
      // Retain the original app object (and resolved tab) to avoid activating a reused PID.
      item.representedObject = row.app.map { NowPlayingTarget(app: $0, tab: row.tab) }
      item.isEnabled = row.app != nil
      let view = NowPlayingRowView(
        name: row.name, icon: row.icon ?? row.app?.icon, levels: row.levels,
        roundedIcon: row.isFavicon, tooltip: row.tooltip)
      item.view = view
      menu.insertItem(item, at: insertionIndex + items.count)
      items.append(item)
      rowViews.append(view)
    }
    if rows.isEmpty {
      appendDisabled(
        enumerationFailed ? "Audio temporarily unavailable" : "silence", to: menu,
        at: insertionIndex + items.count)
    }
    if metersUnavailable && !rows.isEmpty {
      appendDisabled(
        "meters need System Audio Recording permission", to: menu, at: insertionIndex + items.count)
    }
  }

  private func appendDisabled(_ title: String, to menu: NSMenu, at index: Int) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    menu.insertItem(item, at: index)
    items.append(item)
  }
  private func redrawMeters() {
    guard isOpen else { return }
    for view in rowViews { view.updateLevel() }
  }
  @objc private func activate(_ sender: NSMenuItem) {
    guard let target = sender.representedObject as? NowPlayingTarget, !target.app.isTerminated
    else { return }
    let app = target.app
    if let tab = target.tab {
      browserFocusQueue.async {
        NowPlayingBrowserFocus.focus(tab: tab)
      }
      return
    }
    if AXIsProcessTrusted(), NowPlayingBrowserFocus.isWebHandler(app) {
      let titles = app.bundleIdentifier == "com.apple.Safari" ? safariTitles : []
      browserFocusQueue.async {
        if let tab = NowPlayingBrowserFocus.audibleTabs(in: app, includeURLs: true, soundTitles: titles).first {
          NowPlayingBrowserFocus.focus(tab: tab)
        } else {
          DispatchQueue.main.async {
            if !app.isTerminated { app.activate(options: [.activateIgnoringOtherApps]) }
          }
        }
      }
      return
    }
    app.activate(options: [.activateIgnoringOtherApps])
  }
  var timersAreNil: Bool { processTimer == nil && meterTimer == nil }
  var sessionIsNil: Bool { session == nil }

  /// Completion runs on the worker queue after taps, devices and IOProcs are
  /// nil. There is no synchronous CoreAudio work on the calling main thread.
  func close(_ completion: (() -> Void)? = nil) {
    precondition(Thread.isMainThread)
    isOpen = false
    generation += 1
    processTimer?.invalidate()
    processTimer = nil
    meterTimer?.invalidate()
    meterTimer = nil
    let old = session
    session = nil
    sampling = false
    lastSnapshot = nil
    browserTabs.removeAll()
    browserScanInFlight.removeAll()
    rows.removeAll()
    for view in rowViews { view.levels.removeAll() }
    if let old { old.close(completion) } else { completion?() }
    assert(timersAreNil && sessionIsNil)
  }
  deinit {
    processTimer?.invalidate()
    meterTimer?.invalidate()
    session?.close()
  }
}

/// A menu view keeps native menu actions/keyboard navigation and supplies mouse
/// handling because NSMenu does not dispatch actions for a custom item's view.
final class NowPlayingRowView: NSView {
  private let name: String
  private var icon: NSImage?
  private var roundedIcon: Bool
  var levels: [NowPlayingLevel]
  private var rms: Float = 0
  private var peak: Float = 0
  private var tracking: NSTrackingArea?
  private var hovered = false
  override var isFlipped: Bool { true }

  init(
    name: String, icon: NSImage?, levels: [NowPlayingLevel],
    roundedIcon: Bool = false, tooltip: String? = nil
  ) {
    self.name = name
    self.icon = icon
    self.roundedIcon = roundedIcon
    self.levels = levels
    super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
    autoresizingMask = [.width]
    self.toolTip = tooltip
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Activate \(name)")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func updateIcon(_ nextIcon: NSImage?, rounded: Bool) {
    if icon !== nextIcon || roundedIcon != rounded {
      icon = nextIcon
      roundedIcon = rounded
      needsDisplay = true
    }
  }
  override func updateTrackingAreas() {
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
    super.updateTrackingAreas()
  }
  override func mouseEntered(with event: NSEvent) {
    hovered = true
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    hovered = false
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    performAction()
  }
  override func accessibilityPerformPress() -> Bool { performAction() }
  @discardableResult private func performAction() -> Bool {
    guard let item = enclosingMenuItem, item.isEnabled, let menu = item.menu,
      let action = item.action
    else { return false }
    menu.cancelTracking()
    return NSApp.sendAction(action, to: item.target, from: item)
  }
  func updateLevel() {
    let values = levels.map(\.levels)
    // A browser can own multiple audio helpers: show the strongest helper,
    // rather than claiming separate processes form a phase-coherent mix.
    let nextRMS = values.map(\.rms).max() ?? 0
    let nextPeak = values.map(\.peak).max() ?? 0
    if nextRMS != rms || nextPeak != peak || enclosingMenuItem?.isHighlighted == true {
      rms = nextRMS
      peak = nextPeak
      needsDisplay = true
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    let highlighted =
      (hovered || enclosingMenuItem?.isHighlighted == true) && enclosingMenuItem?.isEnabled != false
    if highlighted {
      NSColor.selectedContentBackgroundColor.setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
    let fallback = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
    let image = icon ?? fallback
    let iconRect = NSRect(x: 14, y: 6, width: 16, height: 16)
    if roundedIcon {
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(roundedRect: iconRect, xRadius: 3, yRadius: 3).addClip()
      image?.draw(
        in: iconRect, from: .zero, operation: .sourceOver,
        fraction: 1, respectFlipped: true, hints: nil)
      NSGraphicsContext.restoreGraphicsState()
    } else {
      image?.draw(
        in: iconRect, from: .zero, operation: .sourceOver,
        fraction: 1, respectFlipped: true, hints: nil)
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let meterWidth: CGFloat = levels.isEmpty ? 0 : 66
    (name as NSString).draw(
      in: NSRect(x: 38, y: 5, width: bounds.width - 54 - meterWidth, height: 19),
      withAttributes: [
        .font: NSFont.menuFont(ofSize: 13),
        .foregroundColor: highlighted
          ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
        .paragraphStyle: paragraph,
      ])
    guard !levels.isEmpty else { return }
    let bar = NSRect(x: bounds.width - 72, y: 11, width: 56, height: 6)
    NSColor.labelColor.withAlphaComponent(0.12).setFill()
    NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
    // -60…0 dBFS gives quiet streams useful visual range. Amber is peak
    // >= -3 dBFS, not a fabricated indication of device output volume.
    let fraction = rms > 0 ? max(0, min(1, (20 * log10(Double(rms)) + 60) / 60)) : 0
    if fraction > 0 {
      (peak >= 0.708 ? NSColor.systemOrange : NSColor.systemGreen).setFill()
      NSBezierPath(
        roundedRect: NSRect(
          x: bar.minX, y: bar.minY, width: max(2, bar.width * fraction), height: bar.height),
        xRadius: 3, yRadius: 3
      ).fill()
    }
  }
}
