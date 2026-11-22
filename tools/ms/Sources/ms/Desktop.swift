import AppKit
import ApplicationServices

func frameJSON(_ r: CGRect) -> [String: Double] {
    ["x": r.origin.x, "y": r.origin.y, "width": r.width, "height": r.height]
}

func frameText(_ r: CGRect) -> String {
    "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))"
}

@MainActor
func screenID(_ screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

@MainActor
func desktopScreens() -> [NSScreen] {
    // AppKit must initialize before NSScreen reflects secondary menu bars.
    _ = NSApplication.shared
    return NSScreen.screens
}

@MainActor
func screens() -> Output {
    // AppKit is bottom-left based; CGWindow and screencapture use top-left global points.
    let displays = desktopScreens()
    let desktopTop = displays.first?.frame.maxY ?? 0
    var lines: [String] = []
    let rows: [[String: Any]] = displays.map { screen in
        let id = screenID(screen)
        let rect = CGDisplayBounds(id)
        let visible = screen.visibleFrame
        let visibleCG = flipScreenRect(visible, primaryTop: desktopTop)
        let hz = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        let main = id == CGMainDisplayID()
        let builtIn = CGDisplayIsBuiltin(id) != 0
        lines.append("\(id) \(screen.localizedName) | \(frameText(rect)) | visible \(frameText(visibleCG)) | \(screen.backingScaleFactor)× | \(hz > 0 ? String(format: "%.1f Hz", hz) : "refresh unknown/variable")\(main ? " | main" : "")\(builtIn ? " | built-in" : "")")
        return ["id": id, "name": screen.localizedName, "frame": frameJSON(rect),
                "visibleFrame": frameJSON(visibleCG), "scale": screen.backingScaleFactor,
                "refreshRate": hz > 0 ? hz as Any : NSNull(), "main": main, "builtIn": builtIn]
    }
    return Output(json: ["screens": rows, "coordinateSystem": "global points, origin at primary display top-left, y increases downward"], text: lines.joined(separator: "\n"))
}

@MainActor
func apps() -> Output {
    let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    let rows: [[String: Any]] = running.map {
        ["name": $0.localizedName ?? "", "bundleId": $0.bundleIdentifier ?? "", "pid": $0.processIdentifier,
         "frontmost": $0.isActive, "hidden": $0.isHidden]
    }
    let lines = running.map {
        "\($0.processIdentifier) \($0.localizedName ?? "?") (\($0.bundleIdentifier ?? "?"))\($0.isActive ? " | frontmost" : "")\($0.isHidden ? " | hidden" : "")"
    }
    return Output(json: ["apps": rows], text: lines.joined(separator: "\n"))
}

struct Window {
    let id: UInt32
    let app: String
    let pid: pid_t
    let title: String
    let frame: CGRect
    let layer: Int
    let zOrder: Int
    let onScreen: Bool
}

func windowList(allSpaces: Bool) throws -> [Window] {
    let options: CGWindowListOption = allSpaces ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        throw Failure("cannot enumerate windows; a logged-in graphical macOS session is required")
    }
    return list.enumerated().compactMap { index, info in
        guard let id = info[kCGWindowNumber as String] as? UInt32,
              let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return Window(id: id, app: info[kCGWindowOwnerName as String] as? String ?? "",
                      pid: pid, title: info[kCGWindowName as String] as? String ?? "", frame: rect,
                      layer: info[kCGWindowLayer as String] as? Int ?? 0, zOrder: index,
                      onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }
}

@MainActor
func windows(_ args: [String]) throws -> Output {
    let parsed = try Arguments(args, values: ["--app"], switches: ["--all-spaces", "--all-layers"])
    try parsed.count(0)
    let allSpaces = parsed.flags.contains("--all-spaces")
    let displays = NSScreen.screens.map { screen in
        let id = screenID(screen)
        return (id, CGDisplayBounds(id))
    }
    let list = try windowList(allSpaces: allSpaces).filter { window in
        guard parsed.flags.contains("--all-layers") || window.layer == 0 else { return false }
        guard let app = parsed.options["--app"], !app.isEmpty else { return true }
        let bundle = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier ?? ""
        return window.app.localizedCaseInsensitiveContains(app) || bundle.caseInsensitiveCompare(app) == .orderedSame
    }
    let rows: [[String: Any]] = list.map { window in
        var display: CGDirectDisplayID?
        var largestArea: CGFloat = 0
        for (id, bounds) in displays {
            let overlap = bounds.intersection(window.frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > largestArea { display = id; largestArea = area }
        }
        return ["id": window.id, "app": window.app, "pid": window.pid, "title": window.title,
                "frame": frameJSON(window.frame), "screenId": display as Any? ?? NSNull(),
                "layer": window.layer, "zOrder": window.zOrder, "onScreen": window.onScreen]
    }
    var notes: [String] = []
    if !CGPreflightScreenCaptureAccess() {
        notes.append("Window titles may be empty without Screen Recording permission for the calling terminal or agent host.")
    }
    if allSpaces { notes.append("All Spaces includes off-screen/minimized windows reported by WindowServer; macOS may omit windows on other Spaces.") }
    let lines = zip(list, rows).map { window, row in
        let screen = (row["screenId"] as? UInt32).map(String.init) ?? "none"
        return "\(window.id) \(window.app) [pid \(window.pid)] | \(oneLine(window.title)) | \(frameText(window.frame)) | screen \(screen) | layer \(window.layer) z \(window.zOrder)\(window.onScreen ? "" : " | off-screen")"
    }
    return Output(json: ["windows": rows, "notes": notes], text: (lines + notes.map { "Note: \($0)" }).joined(separator: "\n"))
}

func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let p = axAttribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = axAttribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(p, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeDowncast(s, to: AXValue.self), .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
}

func announceWindowFocus(pid: pid_t, id: UInt32?) {
    var info: [String: Any] = ["pid": pid]
    if let id { info["windowID"] = id }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.machinespirit.leader.window.focus"), object: nil,
        userInfo: info, deliverImmediately: true)
}

@MainActor
func focus(_ args: [String]) throws -> Output {
    let parsed = try Arguments(args)
    try parsed.count(1)
    let target = parsed.positionals[0]
    var app: NSRunningApplication
    var focusedWindow: UInt32?
    if target.allSatisfy(\.isNumber), !target.isEmpty {
        let id = try positiveID(target)
        guard AXIsProcessTrusted() else {
            throw Failure("Accessibility permission required: enable the calling terminal or agent host in System Settings > Privacy & Security > Accessibility, then restart it")
        }
        guard let window = try windowList(allSpaces: true).first(where: { $0.id == id }),
              let owner = NSRunningApplication(processIdentifier: window.pid) else { throw Failure("window \(id) no longer exists") }
        app = owner
        let element = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(element, 2)
        guard let axWindows = axAttribute(element, kAXWindowsAttribute) as? [AXUIElement] else {
            throw Failure("app does not expose accessible windows (or Accessibility access was denied)")
        }
        let candidates = axWindows.filter {
            let title = axAttribute($0, kAXTitleAttribute) as? String ?? ""
            return axFrame($0).map { sameFrame($0, window.frame) } == true && (window.title.isEmpty || title == window.title)
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw Failure("cannot uniquely match window \(id) by pid, frame and title; refresh ms windows and retry")
        }
        if (axAttribute(candidate, kAXMinimizedAttribute) as? Bool) == true {
            guard AXUIElementSetAttributeValue(candidate, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                throw Failure("cannot unminimize window \(id)")
            }
        }
        guard app.activate(options: [.activateAllWindows]) else { throw Failure("macOS refused app activation") }
        let raised = AXUIElementPerformAction(candidate, kAXRaiseAction as CFString)
        guard raised == .success else { throw Failure("app activated but AXRaise failed for window \(id) (AX error \(raised.rawValue))") }
        focusedWindow = id
    } else {
        let matching = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier?.caseInsensitiveCompare(target) == .orderedSame || $0.localizedName?.caseInsensitiveCompare(target) == .orderedSame
        }
        guard matching.count == 1, let found = matching.first else {
            throw Failure(matching.isEmpty ? "no running app named \(target); use ms apps" : "ambiguous app name; use a window ID")
        }
        app = found
        guard app.activate(options: [.activateAllWindows]) else { throw Failure("macOS refused app activation") }
    }
    announceWindowFocus(pid: app.processIdentifier, id: focusedWindow)
    return Output(json: ["app": app.localizedName ?? "", "pid": app.processIdentifier,
                         "windowId": focusedWindow as Any? ?? NSNull(), "activated": true],
                  text: "Activated \(app.localizedName ?? target)\(focusedWindow.map { " window \($0)" } ?? "")")
}
