import AppKit
import ApplicationServices
import Darwin

private let fullscreenAttribute = "AXFullScreen"

@MainActor
private func availableScreens() throws -> [NSScreen] {
    let screens = desktopScreens()
    guard !screens.isEmpty else { throw Failure("no screens available; a graphical macOS session is required") }
    return screens
}

@MainActor
func mouse() throws -> Output {
    let screens = try availableScreens()
    let point = NSEvent.mouseLocation
    let screen = screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? screens[0]
    return Output(json: ["x": point.x, "y": point.y, "screen": screenID(screen),
                         "coordinateSystem": "AppKit global points, primary bottom-left, y up",
                         "cgX": point.x, "cgY": screens[0].frame.maxY - point.y,
                         "frame": frameJSON(screen.frame), "visibleFrame": frameJSON(screen.visibleFrame)],
                  text: "\(point.x),\(point.y) screen=\(screenID(screen))")
}

@MainActor
private func targetApp(_ name: String?) throws -> NSRunningApplication {
    guard let name else {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw Failure("no frontmost application") }
        return app
    }
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame ||
        $0.bundleIdentifier?.caseInsensitiveCompare(name) == .orderedSame
    }
    guard apps.count == 1, let app = apps.first else {
        throw Failure(apps.isEmpty ? "no running app named \(name); use ms apps" : "ambiguous app name; use its bundle ID")
    }
    return app
}

private func appElement(_ pid: pid_t) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    // Bound stalls from unresponsive apps; no retry loops for frame writes.
    AXUIElementSetMessagingTimeout(app, 0.15)
    return app
}

private func windowElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
}

private func targetWindow(_ app: AXUIElement, rectangle: Bool = false) throws -> AXUIElement {
    if let focused = windowElement(axAttribute(app, kAXFocusedWindowAttribute)) { return focused }
    if !rectangle, let main = windowElement(axAttribute(app, kAXMainWindowAttribute)) { return main }
    if let windows = axAttribute(app, kAXWindowsAttribute) as? [AXUIElement] {
        if rectangle, let first = windows.first { return first }
        if let standard = windows.first(where: { axAttribute($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole }) {
            return standard
        }
    }
    throw Failure("No accessible window to move", exitCode: 11)
}

/// Read each window's attributes in ONE AX round trip (especially important for tile-all).
private struct AXWindowSnapshot {
    let element: AXUIElement
    let frame: CGRect?
    let title: String
    let standard: Bool
    let fullscreen: Bool
    let minimized: Bool

    init(_ element: AXUIElement) throws {
        let names = [kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute,
                     kAXSubroleAttribute, fullscreenAttribute, kAXMinimizedAttribute]
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, names as CFArray,
                                                            AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard result == .success, let values = values as? [Any], values.count == names.count else {
            throw Failure("cannot read window attributes (AX error \(result.rawValue))")
        }
        self.element = element
        title = values[2] as? String ?? ""
        standard = values[3] as? String == kAXStandardWindowSubrole
        fullscreen = values[4] as? Bool ?? false
        minimized = values[5] as? Bool ?? false
        let p = values[0] as CFTypeRef, s = values[1] as CFTypeRef
        var point = CGPoint.zero, size = CGSize.zero
        guard CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
              AXValueGetValue(unsafeDowncast(p, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(s, to: AXValue.self), .cgSize, &size),
              [point.x, point.y, size.width, size.height].allSatisfy(\.isFinite), size.width > 0, size.height > 0 else {
            frame = nil
            return
        }
        frame = CGRect(origin: point, size: size)
    }

    func cgID(pid: pid_t, windows: [Window]) -> UInt32? {
        guard let frame else { return nil }
        let matches = windows.filter { $0.pid == pid && $0.layer == 0 && sameFrame($0.frame, frame) }
        let titled = matches.filter { !$0.title.isEmpty && $0.title == title }
        if titled.count == 1 { return titled[0].id }
        return matches.count == 1 ? matches[0].id : nil
    }

    func key(pid: pid_t, windows: [Window]) -> String {
        if let id = cgID(pid: pid, windows: windows) { return "\(pid):\(id)" }
        // Swift Hasher is randomized per process. FNV-1a remains stable between CLI calls.
        let hash = title.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return "\(pid):title-\(String(hash, radix: 16))"
    }
}

private func setAX(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) throws {
    let result = AXUIElementSetAttributeValue(element, attribute as CFString, value)
    guard result == .success else { throw Failure("cannot set \(attribute) (AX error \(result.rawValue))") }
}

private func setFrame(_ element: AXUIElement, _ frame: CGRect) throws {
    var point = frame.origin, size = frame.size
    guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else {
        throw Failure("cannot encode window frame")
    }
    // Attempt the final position even when size is refused; never retry/clamp in a loop.
    let first = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
    let resized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
    let last = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
    guard first == .success, resized == .success, last == .success else {
        throw Failure("window refused frame (AX position/size/position errors \(first.rawValue)/\(resized.rawValue)/\(last.rawValue))")
    }
}

private func setHalfFrame(_ element: AXUIElement, from current: CGRect, to target: CGRect,
                          within visible: CGRect) throws -> CGRect {
    // AppKit may constrain a resize to the display that owns most of the
    // window after the first position write. Shrink before moving so a tall
    // window cannot straddle the seam and acquire the neighbor's constraints.
    var compact = CGSize(width: min(current.width, target.width), height: min(current.height, target.height))
    if compact != current.size, let size = AXValueCreate(.cgSize, &compact) {
        try? setAX(element, kAXSizeAttribute, size)
    }
    try setFrame(element, target)
    guard let first = axFrame(element) else { throw Failure("cannot verify the window's half placement") }
    if matchesHalfFrame(first, target) { return first }

    // A resize right on a display seam can still be constrained by the
    // neighboring display. Fit once inside the destination, then set the origin.
    var origin = visible.origin
    var targetOrigin = target.origin
    var targetSize = target.size
    if let inside = AXValueCreate(.cgPoint, &origin),
       let size = AXValueCreate(.cgSize, &targetSize) {
        try? setAX(element, kAXPositionAttribute, inside)
        try? setAX(element, kAXSizeAttribute, size)
        if let fitted = axFrame(element) {
            // A minimum height can exceed the requested half. Keep the
            // window inside the usable bounds by letting it grow inward.
            targetOrigin.y = min(targetOrigin.y, max(visible.minY, visible.maxY - fitted.height))
        }
        if let final = AXValueCreate(.cgPoint, &targetOrigin) {
            try setAX(element, kAXPositionAttribute, final)
        }
    }
    guard let landed = axFrame(element) else { throw Failure("cannot verify the window's half placement") }
    return landed
}

private func setFullscreen(_ fullscreen: Bool, on element: AXUIElement, before: CGRect) throws -> CGRect {
    let desired = fullscreen as CFBoolean
    try setAX(element, fullscreenAttribute, desired)
    let start = ProcessInfo.processInfo.systemUptime
    let deadline = start + 2.5
    var lastFrame: CGRect?
    var stableSince: TimeInterval = 0
    var retried = false
    repeat {
        let now = ProcessInfo.processInfo.systemUptime
        let state = axAttribute(element, fullscreenAttribute) as? Bool
        if state == fullscreen, let frame = axFrame(element) {
            if frame != lastFrame { lastFrame = frame; stableSince = now }
            // AXFullScreen can change while the window still reports its old frame.
            // An already display-sized window can legitimately keep that geometry.
            if now - stableSince >= (frame == before ? 0.45 : 0.12) { return frame }
        } else {
            lastFrame = nil
            // AppKit can acknowledge a write while its previous native Space
            // animation is still running and then ignore it. Retry once after
            // that animation when AX still explicitly reports the old value.
            if state == !fullscreen, !retried, now - start >= 0.6 {
                try setAX(element, fullscreenAttribute, desired)
                retried = true
            }
        }
        let remaining = deadline - now
        if remaining <= 0 { break }
        Thread.sleep(forTimeInterval: min(0.05, remaining))
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw Failure("window did not finish \(fullscreen ? "entering" : "leaving") fullscreen within 2.5 seconds")
}

private func savePlacementState(_ state: PlacementState) throws {
    do {
        try JSONEncoder().encode(state).write(to: PlacementState.fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: PlacementState.fileURL.path)
    } catch { throw Failure("placement applied but cannot save ladder state: \(error.localizedDescription)") }
}

private func withPlacementLock<T>(_ action: () throws -> T) throws -> T {
    // Each key chord spawns a new CLI process. Read and write the AX state under
    // the same lock so a second request observes the first completed transition.
    let lock = PlacementState.fileURL.deletingPathExtension().appendingPathExtension("lock")
    let fd = Darwin.open(lock.path, O_WRONLY | O_CREAT | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw Failure("cannot open window placement lock") }
    defer { Darwin.close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw Failure("cannot lock window placement") }
    return try action()
}

@MainActor
func runRectangleAction(_ args: [String]) async throws -> Output {
    let parsed = try Arguments(args)
    try parsed.count(1)
    let url = parsed.positionals[0]
    let prefix = "rectangle://execute-action?name="
    let name = url.dropFirst(prefix.count)
    guard url.hasPrefix(prefix), !name.isEmpty,
          name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
          let actionURL = URL(string: url) else {
        throw Failure("expected a Rectangle action URL")
    }
    let exitedFullscreen = try withPlacementLock {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return false }
        let element = appElement(app.processIdentifier)
        if let window = try? targetWindow(element, rectangle: true),
           axAttribute(window, fullscreenAttribute) as? Bool == true {
            guard let frame = axFrame(window) else { throw Failure("window does not expose a valid frame") }
            _ = try setFullscreen(false, on: window, before: frame)
            // Rectangle uses the focused window on receipt. A focus change
            // during the native transition must not move a different window.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let focused = try? targetWindow(element, rectangle: true), CFEqual(window, focused) else {
                throw Failure("focused window changed before Rectangle placement")
            }
            try? FileManager.default.removeItem(at: PlacementState.fileURL)
            return true
        }
        return false
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    _ = try await NSWorkspace.shared.open(actionURL, configuration: configuration)
    return Output(json: ["status": "dispatched", "action": String(name), "exitedFullscreen": exitedFullscreen],
                  text: "Dispatched Rectangle action \(name)")
}

@MainActor
private func placeWindow(_ requested: Placement, appName: String?) throws -> Output {
    let app = try targetApp(appName)
    return try withPlacementLock { try applyPlacement(requested, to: app) }
}

@MainActor
private func applyPlacement(_ requested: Placement, to app: NSRunningApplication) throws -> Output {
    let snapshot = try AXWindowSnapshot(targetWindow(appElement(app.processIdentifier)))
    guard let currentFrame = snapshot.frame else { throw Failure("window does not expose a valid frame") }
    let screens = try availableScreens()
    let primaryTop = screens[0].frame.maxY
    let screenFrames = screens.map { flipScreenRect($0.frame, primaryTop: primaryTop) }
    let fallback = screens.firstIndex { screenID($0) == CGMainDisplayID() } ?? 0
    let source = overlapScreen(currentFrame, screens: screenFrames, fallback: fallback)
    // The board observes arrival. AX writes never wait for animation or acknowledgment.
    func announce(_ frame: CGRect, mode: Placement, windowID: UInt32? = nil) {
        var info: [String: Any] = ["pid": app.processIdentifier, "frame": NSStringFromRect(frame),
                                  "mode": mode.rawValue, "sourceFrame": NSStringFromRect(currentFrame)]
        if let windowID { info["windowID"] = windowID }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.machinespirit.leader.placement"), object: nil, userInfo: info, deliverImmediately: true)
    }
    if requested == .toggleFullscreen {
        if !snapshot.fullscreen {
            let display = screens[source]
            announce(flipScreenRect(display.frame, primaryTop: primaryTop), mode: .fullscreen)
        }
        _ = try setFullscreen(!snapshot.fullscreen, on: snapshot.element, before: currentFrame)
        try? FileManager.default.removeItem(at: PlacementState.fileURL)
        return Output(json: ["status": "requested", "fullscreen": !snapshot.fullscreen],
                      text: snapshot.fullscreen ? "Leaving fullscreen" : "Entering fullscreen")
    }
    if requested.isVerticalHalfStep {
        let visible = screens.map { flipScreenRect($0.visibleFrame, primaryTop: primaryTop) }
        let pid = app.processIdentifier
        let windowID = snapshot.cgID(pid: pid, windows: (try? windowList(allSpaces: false)) ?? [])
        let key = windowID.map { "\(pid):\($0)" }
        let confirmedHalf = key.flatMap {
            PlacementState.read()?.confirmedHalf(key: $0, screen: screenID(screens[source]), frame: currentFrame,
                                                 usable: visible[source], now: Date().timeIntervalSince1970)
        }
        guard let step = verticalHalfStep(for: requested, window: currentFrame, from: source,
                                          screens: screenFrames, visible: visible, confirmedHalf: confirmedHalf) else {
            let direction = requested == .halfDown ? "below" : "above"
            throw Failure("No display directly \(direction) this window", exitCode: 11)
        }
        let before = snapshot.fullscreen
            ? try setFullscreen(false, on: snapshot.element, before: currentFrame) : currentFrame
        let destination = screenID(screens[step.screen])
        let screen = NSScreen.screens.first { screenID($0) == destination } ?? screens[step.screen]
        let usable = flipScreenRect(screen.visibleFrame, primaryTop: primaryTop)
        let target = placementFrame(step.half, visibleFrame: usable, current: before)
        let landed = try setHalfFrame(snapshot.element, from: before, to: target, within: usable)
        let constrained = !matchesHalfFrame(landed, target)
        if constrained {
            let anchoredY = min(target.minY, max(usable.minY, usable.maxY - landed.height))
            guard !matchesHalfFrame(landed, before), overlapScreen(landed, screens: screenFrames) == step.screen,
                  abs(landed.minX - target.minX) <= 3, abs(landed.minY - anchoredY) <= 3 else {
                throw Failure("window did not reach the \(step.half.rawValue) half on the selected display")
            }
        }
        try? FileManager.default.removeItem(at: PlacementState.fileURL)
        if constrained, let key {
            try? savePlacementState(PlacementState(windowKey: key, last: step.half.rawValue, fromFullscreen: false,
                t: Date().timeIntervalSince1970, halfLanding: .init(screen: destination, frame: landed, usable: usable)))
        }
        announce(landed, mode: step.half, windowID: windowID)
        return Output(json: ["status": "requested", "mode": requested.rawValue, "half": step.half.rawValue,
                             "pid": pid, "screen": destination, "frame": frameJSON(target),
                             "observedFrame": frameJSON(landed), "constrained": constrained],
                      text: "Placed \(step.half.rawValue) half on display \(destination)\(constrained ? " (window constrained)" : "")")
    }
    if requested.isDisplayTransfer {
        let xOnly = UserDefaults(suiteName: "com.knollsoft.Rectangle")?.bool(forKey: "screensOrderedByX") ?? false
        guard let index = destinationDisplay(for: requested, from: source, screens: screenFrames, xOnly: xOnly) else {
            throw Failure("No destination display in that direction", exitCode: 11)
        }
        let windowID = snapshot.cgID(pid: app.processIdentifier, windows: (try? windowList(allSpaces: false)) ?? [])
        let windowFrame = snapshot.fullscreen
            ? try setFullscreen(false, on: snapshot.element, before: currentFrame) : currentFrame
        let refreshed = NSScreen.screens
        let sourceScreen = refreshed.first { screenID($0) == screenID(screens[source]) } ?? screens[source]
        let destination = refreshed.first { screenID($0) == screenID(screens[index]) } ?? screens[index]
        let target = transferredFrame(windowFrame,
            from: flipScreenRect(sourceScreen.visibleFrame, primaryTop: primaryTop),
            to: flipScreenRect(destination.visibleFrame, primaryTop: primaryTop))
        announce(target, mode: requested, windowID: windowID)
        let landedFrame: CGRect
        do {
            try setFrame(snapshot.element, target)
            landedFrame = target
        } catch {
            // Fixed-size utilities can accept the move while refusing AXSize.
            // A confirmed landing still fulfills a display transfer.
            guard let actual = axFrame(snapshot.element),
                  screenFrames[index].intersects(actual),
                  overlapScreen(actual, screens: screenFrames) == index else { throw error }
            landedFrame = actual
            announce(actual, mode: requested, windowID: windowID)
        }
        // Moving displays breaks the fullscreen ladder. Arrival observation stays in the board.
        try? FileManager.default.removeItem(at: PlacementState.fileURL)
        return Output(json: ["status": "requested", "mode": requested.rawValue, "pid": app.processIdentifier,
                             "screen": screenID(screens[index]), "frame": frameJSON(landedFrame)],
                      text: "Moved toward display \(screenID(screens[index]))")
    }
    let point = NSEvent.mouseLocation
    let index = requested == .smart || requested == .aim
        ? (screens.firstIndex { $0.frame.contains(point) } ?? screens.firstIndex { $0 == NSScreen.main } ?? fallback)
        : source
    let screen = screens[index]
    let visible = flipScreenRect(screen.visibleFrame, primaryTop: primaryTop)
    let windows = (try? windowList(allSpaces: true)) ?? []
    let key = snapshot.key(pid: app.processIdentifier, windows: windows)
    let windowID = UInt32(key.split(separator: ":").last ?? "")
    let now = Date().timeIntervalSince1970
    let previous = PlacementState.read()
    var mode = requested
    let zone = mouseZone(point, visibleFrame: screen.visibleFrame)
    if requested == .smart { mode = zone }
    if requested == .aim {
        mode = aimedPlacement(zone: zone, current: classifyPlacement(currentFrame, visibleFrame: visible),
                              fullscreen: snapshot.fullscreen, previous: previous, key: key, screen: screenID(screen),
                              now: now, windowIsOnScreen: index == source)
    }
    if requested == .step {
        mode = nextPlacement(classifyPlacement(currentFrame, visibleFrame: visible), fullscreen: snapshot.fullscreen,
                             fromFullscreen: previous?.matches(key, now: now) == true && previous?.fromFullscreen == true)
    }
    let fromFullscreen = (requested == .step || requested == .aim) && snapshot.fullscreen
    var frame: CGRect?
    if mode == .fullscreen {
        if !snapshot.fullscreen { announce(flipScreenRect(screen.frame, primaryTop: primaryTop), mode: mode, windowID: windowID) }
        if !snapshot.fullscreen { _ = try setFullscreen(true, on: snapshot.element, before: currentFrame) }
    } else {
        let windowFrame = snapshot.fullscreen
            ? try setFullscreen(false, on: snapshot.element, before: currentFrame) : currentFrame
        // Native fullscreen can change Dock/menu-bar reservations. Re-read the usable
        // area after leaving, retaining the destination display selected above.
        let destination = NSScreen.screens.first { screenID($0) == screenID(screen) } ?? screen
        let usable = flipScreenRect(destination.visibleFrame, primaryTop: primaryTop)
        let target = placementFrame(mode, visibleFrame: usable, current: windowFrame)
        announce(target, mode: mode, windowID: windowID)
        try setFrame(snapshot.element, target)
        frame = target
    }
    try savePlacementState(PlacementState(windowKey: key, last: mode.rawValue, fromFullscreen: fromFullscreen,
                                          t: Date().timeIntervalSince1970,
                                          aimZone: requested == .aim ? zone : nil, aimScreen: screenID(screen)))
    return Output(json: ["windowKey": key, "pid": app.processIdentifier, "mode": mode.rawValue,
                         "screen": screenID(screen), "frame": frame.map(frameJSON) as Any? ?? NSNull(),
                         "fromFullscreen": fromFullscreen, "status": "requested"],
                  text: "Requested \(mode.rawValue) for \(app.localizedName ?? "app") on screen \(screenID(screen))")
}

@MainActor
private func hideAllWindows() -> Output {
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && !($0.bundleIdentifier ?? "").hasPrefix("com.machinespirit") &&
        !["Leader Key", "MachineSpirit"].contains($0.localizedName ?? "")
    }
    var count = 0
    for app in apps { if app.hide() { count += 1 } }
    return Output(json: ["count": count, "failed": apps.count - count], text: "Hidden \(count) apps")
}

@MainActor
private func cycleWindow(appName: String?) throws -> Output {
    let app = try targetApp(appName)
    let element = appElement(app.processIdentifier)
    guard let elements = axAttribute(element, kAXWindowsAttribute) as? [AXUIElement] else {
        throw Failure("app does not expose accessible windows")
    }
    let snapshots = try elements.map { try AXWindowSnapshot($0) }.filter(\.standard)
    guard snapshots.count > 1 else { throw Failure("app has at most one standard window", exitCode: 11) }
    let cgWindows = try windowList(allSpaces: true)
    let ordered = try snapshots.map { snapshot -> (UInt32, AXWindowSnapshot) in
        guard let id = snapshot.cgID(pid: app.processIdentifier, windows: cgWindows) else {
            throw Failure("cannot uniquely match a window ID for cycling; refresh ms windows and retry")
        }
        return (id, snapshot)
    }.sorted { $0.0 < $1.0 }
    guard Set(ordered.map { $0.0 }).count == ordered.count else { throw Failure("ambiguous window IDs for cycling") }
    let current = windowElement(axAttribute(element, kAXFocusedWindowAttribute)) ?? windowElement(axAttribute(element, kAXMainWindowAttribute))
    let currentIndex = current.flatMap { focused in ordered.firstIndex { CFEqual($0.1.element, focused) } }
    let next = ordered[((currentIndex ?? -1) + 1) % ordered.count]
    if next.1.minimized { try setAX(next.1.element, kAXMinimizedAttribute, kCFBooleanFalse) }
    let result = AXUIElementPerformAction(next.1.element, kAXRaiseAction as CFString)
    guard result == .success else { throw Failure("AXRaise failed (AX error \(result.rawValue))") }
    guard app.activate(options: []) else { throw Failure("window raised but macOS refused app activation") }
    announceWindowFocus(pid: app.processIdentifier, id: next.0)
    return Output(json: ["pid": app.processIdentifier, "windowId": next.0, "status": "requested"],
                  text: "Raised window \(next.0) of \(app.localizedName ?? "app")")
}

@MainActor
func tileAllWindows(onlyPIDs: Set<pid_t>? = nil, underMouse: Bool = false) throws -> Output {
    let allScreens = try availableScreens()
    let primaryTop = allScreens[0].frame.maxY
    let screens = underMouse ? [allScreens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? allScreens[0]] : allScreens
    let bounds = screens.map { flipScreenRect($0.frame, primaryTop: primaryTop) }
    let visible = screens.map { flipScreenRect($0.visibleFrame, primaryTop: primaryTop) }
    var candidates: [(pid: pid_t, snapshot: AXWindowSnapshot, frame: CGRect)] = []
    var failures: [[String: Any]] = []
    for app in NSWorkspace.shared.runningApplications.filter({ app in
        onlyPIDs.map { $0.contains(app.processIdentifier) } ?? (app.activationPolicy == .regular)
    }) {
        if app.isHidden && !app.unhide() {
            failures.append(["pid": app.processIdentifier, "error": "cannot unhide app"])
        }
        let element = appElement(app.processIdentifier)
        guard let windows = axAttribute(element, kAXWindowsAttribute) as? [AXUIElement] else {
            failures.append(["pid": app.processIdentifier, "error": "cannot enumerate accessible windows"])
            continue
        }
        for window in windows {
            do {
                let snapshot = try AXWindowSnapshot(window)
                if snapshot.standard && !snapshot.fullscreen {
                    if snapshot.minimized { try setAX(window, kAXMinimizedAttribute, kCFBooleanFalse) }
                    guard let frame = snapshot.frame else { throw Failure("window does not expose a valid frame") }
                    if frame.width >= 120 && frame.height >= 80 {
                        candidates.append((app.processIdentifier, snapshot, frame))
                    }
                }
            } catch { failures.append(["pid": app.processIdentifier, "error": oneLine(error.localizedDescription)]) }
        }
    }
    let assignments = tileAssignments(frames: candidates.map { $0.frame }, screens: bounds, visibleFrames: visible)
    var placed: [[String: Any]] = []
    for screen in screens.indices {
        let indices = candidates.indices.filter { assignments[$0] == screen }.sorted {
            let a = candidates[$0].frame, b = candidates[$1].frame
            if a.minY != b.minY { return a.minY < b.minY }
            if a.minX != b.minX { return a.minX < b.minX }
            return $0 < $1
        }
        let frames = tileFrames(count: indices.count, visibleFrame: visible[screen])
        for (index, frame) in zip(indices, frames) {
            let candidate = candidates[index]
            do {
                try setFrame(candidate.snapshot.element, frame)
                placed.append(["pid": candidate.pid, "screen": screenID(screens[screen]), "frame": frameJSON(frame)])
            } catch { failures.append(["pid": candidate.pid, "error": oneLine(error.localizedDescription)]) }
        }
    }
    // Tiling breaks any previous fullscreen -> max ladder transition.
    try? FileManager.default.removeItem(at: PlacementState.fileURL)
    return Output(json: ["count": placed.count, "windows": placed, "failures": failures, "status": "requested"],
                  text: "Requested tiling for \(placed.count) windows\(failures.isEmpty ? "" : "; \(failures.count) failures (see --json)")")
}

@MainActor
func win(_ args: [String]) throws -> Output {
    let parsed = try Arguments(args, values: ["--app"])
    guard let verb = parsed.positionals.first else { throw Failure("usage: ms win <place|rectangle|tile-all|hide-all|cycle>") }
    let mode: Placement?
    if verb == "place" {
        try parsed.count(2)
        guard let placement = Placement(rawValue: parsed.positionals[1]) else { throw Failure("unknown placement mode; see ms --help") }
        mode = placement
    } else {
        try parsed.count(1)
        guard ["tile-all", "hide-all", "cycle"].contains(verb) else { throw Failure("unknown win command: \(verb)") }
        guard verb == "cycle" || parsed.options.isEmpty else { throw Failure("--app is only supported by win place and win cycle") }
        mode = nil
    }
    guard verb == "place" || AXIsProcessTrusted() else { throw Failure("Accessibility not granted to the calling process") }
    switch verb {
    case "place":
        do {
            guard AXIsProcessTrusted() else { throw Failure("Accessibility not granted to the calling process") }
            return try placeWindow(mode!, appName: parsed.options["--app"])
        } catch {
            if let mode, mode.isDisplayTransfer || mode.isVerticalHalfStep {
                let reason = (error as? Failure)?.message ?? "Display move unavailable"
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("com.machinespirit.leader.placement.miss"), object: nil,
                    userInfo: ["reason": reason], deliverImmediately: true)
            }
            throw error
        }
    case "tile-all": return try tileAllWindows()
    case "hide-all": return hideAllWindows()
    default: return try cycleWindow(appName: parsed.options["--app"])
    }
}
