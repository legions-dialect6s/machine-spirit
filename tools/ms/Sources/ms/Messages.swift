import AppKit
import ApplicationServices

/// Private entry point for messages-find.sh. Native AX provides direct search
/// focus verification, including Catalyst windows and transient tooltip windows.
@MainActor
func messagesFind(_ args: [String]) throws -> Output {
    try Arguments(args).count(0)
    guard AXIsProcessTrusted() else { throw Failure("Accessibility not granted to the calling process", exitCode: 11) }
    if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").isEmpty {
        _ = try process("/usr/bin/open", ["-b", "com.apple.MobileSMS"])
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var app: NSRunningApplication?
    var root: AXUIElement?
    var window: AXUIElement?
    repeat {
        app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first
        if let app {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.1)
            root = element
            // Catalyst includes tooltips in AXWindows, sometimes before the
            // conversation window. Never choose a tooltip as the search root.
            let windows = axAttribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let standard = windows.filter { axAttribute($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole }
            if let focused = axAttribute(element, kAXFocusedWindowAttribute) {
                window = standard.first { CFEqual($0, focused) }
            }
            if window == nil { window = standard.first }
            if window != nil { break }
        }
        usleep(20000)
    } while ProcessInfo.processInfo.systemUptime < deadline
    guard let root, let window, let app else { throw Failure("Messages has no window", exitCode: 11) }
    _ = app.activate(options: [])
    let searchDeadline = ProcessInfo.processInfo.systemUptime + 2

    func find(_ start: AXUIElement, matching: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [start], index = 0
        while index < queue.count && index < 600 && ProcessInfo.processInfo.systemUptime < searchDeadline {
            let element = queue[index]; index += 1
            if matching(element) { return element }
            let identifier = axAttribute(element, kAXIdentifierAttribute) as? String ?? ""
            if ["TranscriptCollectionView", "MessageEntryView"].contains(identifier) { continue }
            if let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] { queue += children }
        }
        return nil
    }
    func search() -> AXUIElement? {
        find(window) { axAttribute($0, kAXSubroleAttribute) as? String == "AXSearchField" }
    }
    func pressMenu(_ titles: Set<String>) -> Bool {
        guard let menu = axAttribute(root, kAXMenuBarAttribute) else { return false }
        let element = unsafeDowncast(menu, to: AXUIElement.self)
        guard let item = find(element, matching: {
            axAttribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole &&
            titles.contains(axAttribute($0, kAXTitleAttribute) as? String ?? "")
        }) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }
    var field = search()
    if field == nil {
        var revealed = pressMenu(["Show Sidebar", "Show Conversation List"])
        if !revealed, let button = find(window, matching: {
            let role = axAttribute($0, kAXRoleAttribute) as? String
            let description = (axAttribute($0, kAXDescriptionAttribute) as? String ?? "").lowercased()
            return role == kAXButtonRole && ["show sidebar", "sidebar", "show conversation list"].contains(description)
        }) { revealed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success }
        // Tahoe's narrow Catalyst window has no sidebar menu. Find reveals its
        // search surface but does not reliably focus it. Focus is verified below.
        if !revealed { _ = pressMenu(["Find…", "Find..."]) }
        repeat {
            field = search()
            if field != nil { break }
            usleep(20000)
        } while ProcessInfo.processInfo.systemUptime < searchDeadline
    }
    guard let field else { throw Failure("Messages search field unavailable", exitCode: 11) }
    func isFocused() -> Bool {
        guard let focused = axAttribute(root, kAXFocusedUIElementAttribute) else { return false }
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return axAttribute(unsafeDowncast(focused, to: AXUIElement.self), kAXSubroleAttribute) as? String == "AXSearchField"
    }
    _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    if !isFocused() {
        // Catalyst may return AX success without changing focus. Click only a
        // visible search field whose hit-test resolves to that exact AX element.
        guard app.isActive, let frame = axFrame(field), let windowFrame = axFrame(window),
              windowFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
            throw Failure("Messages search is not visible", exitCode: 11)
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit, CFEqual(hit, field) else { throw Failure("Messages search is obscured", exitCode: 11) }
        let clickScript = """
        tell application "System Events"
          if bundle identifier of first application process whose frontmost is true is not "com.apple.MobileSMS" then error "Messages lost focus"
          click at {\(Int(point.x)), \(Int(point.y))}
        end tell
        """
        _ = try process("/usr/bin/osascript", ["-e", clickScript])
        repeat {
            if isFocused() { break }
            usleep(20000)
        } while ProcessInfo.processInfo.systemUptime < searchDeadline
    }
    guard isFocused() else { throw Failure("Messages search focus was not verified", exitCode: 11) }
    // Select an existing query without changing its text or sending keystrokes.
    if let text = axAttribute(field, kAXValueAttribute) as? String, !text.isEmpty {
        var range = CFRange(location: 0, length: text.utf16.count)
        if let value = AXValueCreate(.cfRange, &range) {
            _ = AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value)
        }
    }
    return Output(json: ["focused": "conversation-search"], text: "")
}
