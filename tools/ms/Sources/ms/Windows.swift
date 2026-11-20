import AppKit
import ApplicationServices

private let fullscreenAttribute = "AXFullScreen"

@MainActor
private func availableScreens() throws -> [NSScreen] {
    let screens = NSScreen.screens
    guard !screens.isEmpty else { throw Failure("no screens available; a graphical macOS session is required") }
    return screens
}

@MainActor
func mouse() throws -> Output {
    let screens = try availableScreens()
    let point = NSEvent.mouseLocation
    let screen = screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? screens[0]
    return Output(json: ["x": point.x, "y": point.y, "screen": screenID(screen),
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

private func targetWindow(_ app: AXUIElement) throws -> AXUIElement {
    if let focused = windowElement(axAttribute(app, kAXFocusedWindowAttribute)) { return focused }
    if let main = windowElement(axAttribute(app, kAXMainWindowAttribute)) { return main }
    if let windows = axAttribute(app, kAXWindowsAttribute) as? [AXUIElement],
       let standard = windows.first(where: { axAttribute($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole }) {
        return standard
    }
    throw Failure("app has no accessible focused, main or standard window", exitCode: 11)
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

private func leaveFullscreen(_ element: AXUIElement) throws {
    try setAX(element, fullscreenAttribute, kCFBooleanFalse)
    let deadline = ProcessInfo.processInfo.systemUptime + 1.2
    repeat {
        if let full = axAttribute(element, fullscreenAttribute) as? Bool, !full { return }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if remaining <= 0 { break }
        Thread.sleep(forTimeInterval: min(0.05, remaining))
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw Failure("window did not leave fullscreen within 1.2 seconds")
}

private var placementStateURL: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ms-win-place.json")
}

private func readPlacementState() -> PlacementState? {
    guard let data = try? Data(contentsOf: placementStateURL), data.count <= 4096 else { return nil }
    return try? JSONDecoder().decode(PlacementState.self, from: data)
}

private func savePlacementState(_ state: PlacementState) throws {
    do {
        try JSONEncoder().encode(state).write(to: placementStateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: placementStateURL.path)
    } catch { throw Failure("placement applied but cannot save ladder state: \(error.localizedDescription)") }
}

/// The mover announces intent, writes the real window immediately, and only then
/// samples the same AX window for arrival. Polling never writes intermediate frames.
private struct MoveFeedback {
    let id = UUID().uuidString
    let from: String
    let to: String

    init?(from source: CGRect, to target: CGRect, primaryTop: CGFloat) {
        guard ProcessInfo.processInfo.environment["MS_WINDOW_TRANSITION"] != "0" else { return nil }
        from = NSStringFromRect(flipScreenRect(source, primaryTop: primaryTop))
        to = NSStringFromRect(flipScreenRect(target, primaryTop: primaryTop))
    }

    func post(_ phase: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.machinespirit.win.morph"), object: nil,
            userInfo: ["id": id, "phase": phase, "from": from, "to": to,
                       "time": ProcessInfo.processInfo.systemUptime], deliverImmediately: true)
    }
}

func confirmedArrival(at target: CGRect, timeout: TimeInterval, read: () -> CGRect?) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    repeat {
        guard let current = read() else { return false }
        if sameFrame(current, target) { return true }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        Thread.sleep(forTimeInterval: min(0.035, remaining))
    } while true
}

func placementPoint(_ argument: String) throws -> CGPoint {
    let parts = argument.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]),
          x.isFinite, y.isFinite else { throw Failure("expected --point X,Y in global mouse coordinates") }
    return CGPoint(x: x, y: y)
}

@MainActor
private func placeWindow(_ requested: Placement, appName: String?, pointOverride: CGPoint?) throws -> Output {
    let app = try targetApp(appName)
    let snapshot = try AXWindowSnapshot(targetWindow(appElement(app.processIdentifier)))
    guard let currentFrame = snapshot.frame else { throw Failure("window does not expose a valid frame") }
    let screens = try availableScreens()
    let primaryTop = screens[0].frame.maxY
    let screenFrames = screens.map { flipScreenRect($0.frame, primaryTop: primaryTop) }
    let fallback = screens.firstIndex { screenID($0) == CGMainDisplayID() } ?? 0
    let point = pointOverride ?? NSEvent.mouseLocation
    let currentIndex = overlapScreen(currentFrame, screens: screenFrames, fallback: fallback)
    var index = requested == .smart
        ? (screens.firstIndex { $0.frame.contains(point) } ?? screens.firstIndex { $0 == NSScreen.main } ?? fallback)
        : currentIndex
    if requested.isDisplayTransfer {
        guard let neighbor = destinationDisplay(for: requested, from: currentIndex, screens: screenFrames) else {
            return Output(json: ["status": "unchanged", "screen": screenID(screens[currentIndex]),
                                 "mode": requested.rawValue], text: "No display in that direction")
        }
        index = neighbor
    }
    let screen = screens[index]
    let visible = flipScreenRect(screen.visibleFrame, primaryTop: primaryTop)
    let key = snapshot.key(pid: app.processIdentifier, windows: (try? windowList(allSpaces: true)) ?? [])
    let now = Date().timeIntervalSince1970
    let previous = readPlacementState()
    var mode = requested
    if requested == .smart { mode = mouseZone(point, visibleFrame: screen.visibleFrame) }
    if requested == .step {
        mode = nextPlacement(classifyPlacement(currentFrame, visibleFrame: visible), fullscreen: snapshot.fullscreen,
                             fromFullscreen: previous?.matches(key, now: now) == true && previous?.fromFullscreen == true)
    }
    let fromFullscreen = requested == .step && snapshot.fullscreen
    var frame: CGRect?
    var cue: MoveFeedback?
    var arrived = false
    defer { cue?.post(arrived ? "landed" : "cancel") }
    let target: CGRect
    if mode == .fullscreen {
        target = screenFrames[index]
        cue = MoveFeedback(from: currentFrame, to: target, primaryTop: primaryTop)
        cue?.post("begin")
        if !snapshot.fullscreen { try setAX(snapshot.element, fullscreenAttribute, kCFBooleanTrue) }
    } else {
        if snapshot.fullscreen { try leaveFullscreen(snapshot.element) }
        // The Dock/menu-bar reservations can change when exiting native fullscreen.
        let destination = NSScreen.screens.first { screenID($0) == screenID(screen) } ?? screen
        let usable = flipScreenRect(destination.visibleFrame, primaryTop: primaryTop)
        if requested.isDisplayTransfer {
            let source = flipScreenRect(screens[currentIndex].visibleFrame, primaryTop: primaryTop)
            target = transferredFrame(currentFrame, from: source, to: usable)
        } else {
            target = placementFrame(mode, visibleFrame: usable, current: currentFrame)
        }
        cue = MoveFeedback(from: currentFrame, to: target, primaryTop: primaryTop)
        cue?.post("begin")
        if snapshot.fullscreen || !sameFrame(currentFrame, target) { try setFrame(snapshot.element, target) }
        frame = target
    }
    // Record the committed command before waiting, so rapid ladder presses see the new rung.
    try savePlacementState(PlacementState(windowKey: key, last: mode.rawValue, fromFullscreen: fromFullscreen, t: now))
    if cue != nil {
        arrived = confirmedArrival(at: target, timeout: mode == .fullscreen ? 1.3 : 0.55) { axFrame(snapshot.element) }
    }
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
    try? FileManager.default.removeItem(at: placementStateURL)
    return Output(json: ["count": placed.count, "windows": placed, "failures": failures, "status": "requested"],
                  text: "Requested tiling for \(placed.count) windows\(failures.isEmpty ? "" : "; \(failures.count) failures (see --json)")")
}

@MainActor
private func resizeWindow(by delta: Int, appName: String?) throws -> Output {
    let app = try targetApp(appName)
    let snapshot = try AXWindowSnapshot(targetWindow(appElement(app.processIdentifier)))
    guard let frame = snapshot.frame, !snapshot.fullscreen else { throw Failure("window is not resizable in this state") }
    let screens = try availableScreens()
    let top = screens[0].frame.maxY
    let index = overlapScreen(frame, screens: screens.map { flipScreenRect($0.frame, primaryTop: top) })
    let target = resizedFrame(frame, delta: CGFloat(delta), within: flipScreenRect(screens[index].visibleFrame, primaryTop: top))
    if frame != target {
        let cue = MoveFeedback(from: frame, to: target, primaryTop: top)
        cue?.post("begin")
        var arrived = false
        defer { cue?.post(arrived ? "landed" : "cancel") }
        try setFrame(snapshot.element, target)
        if cue != nil { arrived = confirmedArrival(at: target, timeout: 0.55) { axFrame(snapshot.element) } }
    }
    return Output(json: ["frame": frameJSON(target), "status": "requested"], text: "Requested window resize")
}

@MainActor
func win(_ args: [String]) throws -> Output {
    let options: Set<String>
    switch args.first {
    case "resize": options = ["--app", "--delta"]
    case "place": options = ["--app", "--point"]
    default: options = ["--app"]
    }
    let parsed = try Arguments(args, values: options)
    let point = try parsed.options["--point"].map(placementPoint)
    guard let verb = parsed.positionals.first else { throw Failure("usage: ms win <place|tile-all|hide-all|cycle>") }
    let mode: Placement?
    if verb == "resize" {
        try parsed.count(1)
        guard let delta = parsed.options["--delta"].flatMap(Int.init) else { throw Failure("expected --delta <points>") }
        guard AXIsProcessTrusted() else { throw Failure("Accessibility not granted to the calling process") }
        return try resizeWindow(by: delta, appName: parsed.options["--app"])
    }
    if verb == "place" {
        try parsed.count(2)
        guard let placement = Placement(rawValue: parsed.positionals[1]) else { throw Failure("unknown placement mode; see ms --help") }
        guard point == nil || placement == .smart else { throw Failure("--point requires win place smart") }
        mode = placement
    } else {
        try parsed.count(1)
        guard ["tile-all", "hide-all", "cycle"].contains(verb) else { throw Failure("unknown win command: \(verb)") }
        guard verb == "cycle" || parsed.options.isEmpty else { throw Failure("--app is only supported by win place and win cycle") }
        mode = nil
    }
    guard AXIsProcessTrusted() else { throw Failure("Accessibility not granted to the calling process") }
    switch verb {
    case "place": return try placeWindow(mode!, appName: parsed.options["--app"], pointOverride: point)
    case "tile-all": return try tileAllWindows()
    case "hide-all": return hideAllWindows()
    default: return try cycleWindow(appName: parsed.options["--app"])
    }
}
