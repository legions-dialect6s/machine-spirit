import AppKit
import IOKit.ps
import Darwin

/// Concurrent children share a deadline. Drain nonblocking pipes to avoid large
/// browser tab lists deadlocking; kill/reap on timeout, never leave collectors behind.
final class PulseChild {
    let task = Process()
    let pipe = Pipe()
    var data = Data()
    var failure: String?
    init(_ executable: String, _ args: [String], includeErrors: Bool = false) {
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = pipe
        task.standardError = includeErrors ? pipe : FileHandle.nullDevice
        do {
            try task.run()
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        } catch { failure = "could not start helper" }
    }
    func drain() {
        guard failure == nil else { return }
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count <= 0 { break }
            if data.count + count > 4 * 1024 * 1024 {
                failure = "helper output exceeded 4 MiB"
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                break
            }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
    static func finish(_ children: [PulseChild], deadline: TimeInterval) {
        while children.contains(where: { $0.task.isRunning }) && ProcessInfo.processInfo.systemUptime < deadline {
            children.forEach { $0.drain() }
            var descriptors = children.filter { $0.task.isRunning }.map {
                pollfd(fd: $0.pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            }
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            if !descriptors.isEmpty { _ = poll(&descriptors, nfds_t(descriptors.count), Int32(min(remaining * 1000, 20))) }
        }
        for child in children {
            if child.task.isRunning {
                child.failure = "helper timed out (3 seconds)"
                kill(child.task.processIdentifier, SIGKILL)
            }
            if child.task.processIdentifier > 0 { child.task.waitUntilExit() }
            child.drain()
        }
    }
    var output: String? {
        guard failure == nil, task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct PulseApp: Codable {
    let name: String
    let bundleId: String?
    let pid: Int32
    let standardWindowsEstimate: Int
    let offScreenWindows: Int
    // CGWindowList has no minimized/AX subrole flag. Null is intentional.
    var minimizedWindows: Int? = nil
    enum CodingKeys: String, CodingKey { case name, bundleId, pid, standardWindowsEstimate, offScreenWindows, minimizedWindows }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encodeIfPresent(bundleId, forKey: .bundleId)
        try c.encode(pid, forKey: .pid); try c.encode(standardWindowsEstimate, forKey: .standardWindowsEstimate)
        try c.encode(offScreenWindows, forKey: .offScreenWindows)
        try c.encode(minimizedWindows, forKey: .minimizedWindows)
    }
}
struct PulseDomain: Codable, Equatable { let domain: String; let count: Int }
struct PulseBrowser: Codable {
    let name: String
    let status: String
    var tabs: Int? = nil
    var duplicateTabs: Int? = nil
    var topDomains: [PulseDomain] = []
}
struct PulseSnapshot: Codable {
    let timestamp: String
    let uptimeSeconds: Double
    let loadAverages: [Double]
    let memoryPressure: String
    let swapUsedBytes: UInt64?
    let freeDiskBytes: UInt64?
    let batteryPercent: Double?
    let batteryCycles: Int?
    let batteryHealth: String?
    let thermalState: String
    let frontmostApp: String?
    let regularAppCount: Int
    let apps: [PulseApp]
    let browsers: [PulseBrowser]
    let tmuxSessions: Int?
    let notes: [String]
    var idleReview: [String]? = nil
}

func idleReview(after seconds: TimeInterval, browsers: [PulseBrowser], apps: [PulseApp]) -> [String]? {
    guard seconds.isFinite, seconds >= 600 else { return nil }
    var suggestions: [String] = []
    for browser in browsers where browser.status == "ok" {
        if let duplicates = browser.duplicateTabs, duplicates > 0 {
            suggestions.append("\(browser.name) has \(duplicates) extra tab\(duplicates == 1 ? "" : "s") with an identical URL. Review before closing.")
        }
    }
    if let finder = apps.first(where: { $0.bundleId == "com.apple.finder" }), finder.standardWindowsEstimate > 1 {
        suggestions.append("Finder has about \(finder.standardWindowsEstimate) windows. Hold Caps after F I and repeat I to gather them as tabs.")
    }
    return suggestions
}

func pulseBrowser(_ name: String, urls: [String]) -> PulseBrowser {
    let valid = urls.filter { !$0.isEmpty && $0 != "missing value" }
    var domains: [String: Int] = [:]
    for raw in valid {
        if let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() {
            domains[host, default: 0] += 1
        }
    }
    let top = domains.map { PulseDomain(domain: $0.key, count: $0.value) }
        .sorted { $0.count == $1.count ? $0.domain < $1.domain : $0.count > $1.count }
    return PulseBrowser(name: name, status: "ok", tabs: urls.count,
                        duplicateTabs: valid.count - Set(valid).count, topDomains: Array(top.prefix(10)))
}

private func browserScript(_ bundle: String) -> String {
    // Bulk property access: two Apple events per browser rather than one per tab.
    """
    with timeout of 3 seconds
      if application id "\(bundle)" is not running then return "NOT_RUNNING"
      tell application id "\(bundle)"
        set tabLists to URL of every tab of every window
      end tell
      set flatURLs to {}
      repeat with windowURLs in tabLists
        set flatURLs to flatURLs & contents of windowURLs
      end repeat
      set AppleScript's text item delimiters to linefeed
      return (count flatURLs) as text & linefeed & (flatURLs as text)
    end timeout
    """
}

var pulseDirectory: URL {
    if let path = ProcessInfo.processInfo.environment["MS_PULSE_DIR"], !path.isEmpty {
        return URL(fileURLWithPath: expandedPath(path), isDirectory: true)
    }
    return homeURL("Library/Application Support/MachineSpirit/pulse")
}

@MainActor
func collectPulse() throws -> PulseSnapshot {
    let started = ProcessInfo.processInfo.systemUptime
    let running = NSWorkspace.shared.runningApplications
    let browserNames = [("Safari", "com.apple.Safari"), ("Chrome", "com.google.Chrome")]
    let activeBrowsers = browserNames.filter { _, bundle in running.contains { $0.bundleIdentifier == bundle } }
    // One osascript amortizes interpreter startup across both browsers.
    let handlers = activeBrowsers.enumerated().map { index, browser in
        "on collect\(index)()\n" + browserScript(browser.1) + "\nend collect\(index)"
    }.joined(separator: "\n")
    let calls = activeBrowsers.enumerated().map { index, browser in
        """
        try
          set resultText to my collect\(index)()
        on error
          set resultText to "UNAVAILABLE"
        end try
        set combined to combined & "MS_BROWSER_\(browser.0)" & linefeed & resultText & linefeed
        """
    }.joined(separator: "\n")
    let browserChild = activeBrowsers.isEmpty ? nil : PulseChild("/usr/bin/osascript", ["-e", handlers + "\nset combined to \"\"\n" + calls + "\nreturn combined"])
    let tmuxPath = (ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        .split(separator: ":").map { String($0) + "/tmux" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    let tmux = tmuxPath.map { PulseChild($0, ["list-sessions", "-F", "#{session_id}"], includeErrors: true) }
    var load = [Double](repeating: 0, count: 3)
    let loadCount = getloadavg(&load, 3)
    if loadCount != 3 { load = [] }
    var level: Int32 = 0, levelSize = MemoryLayout<Int32>.size
    let levelOK = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0
    let pressure = levelOK ? ([1: "normal", 2: "warning", 4: "critical"][Int(level)] ?? "unknown") : "unavailable"
    var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
    let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
    var disk = statfs()
    let diskOK = statfs("/", &disk) == 0
    var battery: Double?
    if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
       let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = d[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { continue }
            battery = current / maximum * 100
        }
    }
    var cycles: Int?, health: String?
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    if service != 0 {
        defer { IOObjectRelease(service) }
        cycles = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        health = IORegistryEntryCreateCFProperty(service, "BatteryHealth" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        if health == nil,
           let maximum = IORegistryEntryCreateCFProperty(service, "AppleRawMaxCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Double,
           let design = IORegistryEntryCreateCFProperty(service, "DesignCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Double, design > 0 {
            health = String(format: "%.0f%% design capacity (estimate)", maximum / design * 100)
        }
    }
    let regular = running.filter { $0.activationPolicy == .regular }
    var notes = ["Standard windows are layer-zero windows at least 120×80; CGWindowList cannot identify minimized windows separately from hidden/other-Space windows. Off-screen counts are not minimized counts."]
    let windows: [Window]
    do { windows = try windowList(allSpaces: true) }
    catch { windows = []; notes.append("Window enumeration unavailable; window estimates are incomplete.") }
    let appRows: [PulseApp] = regular.map { app -> PulseApp in
        let pid = app.processIdentifier
        let owned: [Window] = windows.filter { window in
            guard window.pid == pid, window.layer == 0 else { return false }
            return window.frame.width >= 120 && window.frame.height >= 80
        }
        return PulseApp(name: app.localizedName ?? "?", bundleId: app.bundleIdentifier, pid: app.processIdentifier,
                        standardWindowsEstimate: owned.count, offScreenWindows: owned.filter { !$0.onScreen }.count)
    }.sorted { $0.name == $1.name ? $0.pid < $1.pid : $0.name < $1.name }
    PulseChild.finish((browserChild.map { [$0] } ?? []) + (tmux.map { [$0] } ?? []), deadline: started + 3)
    let browsers = browserNames.map { info -> PulseBrowser in
        guard activeBrowsers.contains(where: { $0.1 == info.1 }), let child = browserChild else { return PulseBrowser(name: info.0, status: "not running") }
        guard let output = child.output else { return PulseBrowser(name: info.0, status: child.failure ?? "automation unavailable") }
        let allLines = output.components(separatedBy: "\n")
        guard let marker = allLines.firstIndex(of: "MS_BROWSER_" + info.0) else { return PulseBrowser(name: info.0, status: "invalid response") }
        let lines = Array(allLines.dropFirst(marker + 1))
        guard let first = lines.first, let count = Int(first), count >= 0, lines.count >= count + 1 else {
            return PulseBrowser(name: info.0, status: "unavailable (browser closed or invalid response)")
        }
        return pulseBrowser(info.0, urls: Array(lines.dropFirst().prefix(count)))
    }
    var sessions: Int?
    if let tmux {
        if let raw = tmux.output { sessions = raw.split(separator: "\n").count }
        else {
            let diagnostic = String(decoding: tmux.data, as: UTF8.self)
            if tmux.failure == nil, tmux.task.terminationStatus == 1,
               diagnostic.contains("no server running") || (diagnostic.contains("error connecting to") && diagnostic.contains("No such file or directory")) {
                sessions = 0
            } else { notes.append("tmux session count unavailable (helper failure or timeout).") }
        }
    }
    let thermal: String
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: thermal = "nominal"
    case .fair: thermal = "fair"
    case .serious: thermal = "serious"
    case .critical: thermal = "critical"
    @unknown default: thermal = "unknown"
    }
    let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
    // CoreGraphics defines kCGAnyInputEventType as UINT32_MAX in C.
    let anyInput = CGEventType(rawValue: UInt32.max)!
    let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    return PulseSnapshot(timestamp: date.ISO8601Format(), uptimeSeconds: ProcessInfo.processInfo.systemUptime,
                         loadAverages: load, memoryPressure: pressure, swapUsedBytes: swapOK ? swap.xsu_used : nil,
                         freeDiskBytes: diskOK ? UInt64(disk.f_bavail) * UInt64(disk.f_bsize) : nil,
                         batteryPercent: battery, batteryCycles: cycles, batteryHealth: health, thermalState: thermal,
                         frontmostApp: NSWorkspace.shared.frontmostApplication?.localizedName, regularAppCount: regular.count,
                         apps: appRows, browsers: browsers, tmuxSessions: sessions, notes: notes,
                         idleReview: idleReview(after: idleSeconds, browsers: browsers, apps: appRows))
}

func appendPulse(_ snapshot: PulseSnapshot, directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = directory.appendingPathComponent(String(snapshot.timestamp.prefix(7)) + ".jsonl")
    let fd = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw Failure("cannot open pulse log: \(String(cString: strerror(errno)))") }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { throw Failure("pulse log must be an owned regular file") }
    guard flock(fd, LOCK_EX) == 0 else { throw Failure("cannot lock pulse log") }
    defer { flock(fd, LOCK_UN) }
    guard fchmod(fd, 0o600) == 0 else { throw Failure("cannot secure pulse log") }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(snapshot); data.append(10)
    let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    guard written == data.count else { throw Failure("incomplete pulse log write") }
    return file
}

func pulseSummary(_ snapshots: [PulseSnapshot], hours: Int, skipped: Int = 0) -> Output {
    let rows = snapshots.sorted { $0.timestamp < $1.timestamp }
    func metric(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else { return ["samples": 0, "average": NSNull(), "peak": NSNull()] }
        return ["samples": values.count, "average": values.reduce(0, +) / Double(values.count), "peak": values.max()!]
    }
    let load = metric(rows.compactMap { $0.loadAverages.first })
    let load5 = metric(rows.compactMap { $0.loadAverages.count > 1 ? $0.loadAverages[1] : nil })
    let load15 = metric(rows.compactMap { $0.loadAverages.count > 2 ? $0.loadAverages[2] : nil })
    let swap = metric(rows.compactMap { $0.swapUsedBytes.map { Double($0) } })
    let appCount = metric(rows.map { Double($0.regularAppCount) })
    let windowCount = metric(rows.map { Double($0.apps.reduce(0) { $0 + $1.standardWindowsEstimate }) })
    var front: [String: Int] = [:], pile: [String: Int] = [:], pressure: [String: Int] = [:], thermal: [String: Int] = [:]
    for row in rows {
        if let app = row.frontmostApp { front[app, default: 0] += 1 }
        pressure[row.memoryPressure, default: 0] += 1; thermal[row.thermalState, default: 0] += 1
        for app in row.apps { pile[app.name] = max(pile[app.name] ?? 0, app.standardWindowsEstimate) }
    }
    let frontRows = front.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    var browserRows: [[String: Any]] = []
    for name in ["Safari", "Chrome"] {
        let samples = rows.compactMap { $0.browsers.first { $0.name == name && $0.status == "ok" } }
        let tabs = samples.compactMap(\.tabs), duplicates = samples.compactMap(\.duplicateTabs)
        browserRows.append(["name": name, "tabs": metric(tabs.map { Double($0) }), "duplicateTabs": metric(duplicates.map { Double($0) }),
                            "tabChange": tabs.count > 1 ? (tabs.last! - tabs.first!) as Any : NSNull(),
                            "latestTopDomains": samples.last?.topDomains.map { ["domain": $0.domain, "count": $0.count] as [String: Any] } ?? [],
                            "unavailableSamples": rows.count - samples.count])
    }
    let swapValues = rows.compactMap(\.swapUsedBytes)
    let growth = swapValues.count > 1 ? Double(swapValues.last!) - Double(swapValues.first!) : nil
    let minimumDisk = rows.compactMap(\.freeDiskBytes).min()
    var notes = ["Hourly samples describe observations, not time spent. Missing browser samples are excluded, never counted as zero.",
                 "Window counts are CGWindowList estimates; minimized counts are unavailable without AX."]
    if rows.count < 2 { notes.append("Fewer than two samples: trends are not established.") }
    if let growth, growth > 1_073_741_824 { notes.append(String(format: "Swap grew %.2f GiB across available samples.", growth / 1_073_741_824)) }
    if let minimumDisk, minimumDisk < 10 * 1_073_741_824 { notes.append("Low disk: less than 10 GiB free in at least one sample.") }
    if rows.contains(where: { $0.memoryPressure == "critical" || ["serious", "critical"].contains($0.thermalState) }) { notes.append("Elevated memory pressure or thermal state observed.") }
    if skipped > 0 { notes.append("Skipped \(skipped) malformed log line(s).") }
    func display(_ metric: [String: Any]) -> String {
        guard let average = metric["average"] as? Double, let peak = metric["peak"] as? Double else { return "n/a" }
        return String(format: "average %.2f, peak %.2f", average, peak)
    }
    var lines = ["Pulse: \(rows.count) samples in the last \(hours) hours", "Load (1m): \(display(load))",
                 "Regular apps: \(display(appCount))", "Standard windows (estimate): \(display(windowCount))",
                 "Swap bytes: \(display(swap))", "Most frontmost: " + frontRows.prefix(5).map { "\($0.key) (\($0.value) samples)" }.joined(separator: ", ")]
    for browser in browserRows {
        lines.append("\(browser["name"]!): tabs \(display(browser["tabs"] as! [String: Any])); duplicates \(display(browser["duplicateTabs"] as! [String: Any])); tab change \(browser["tabChange"] is NSNull ? "n/a" : String(describing: browser["tabChange"]!))")
    }
    lines.append("Load (5m): \(display(load5)); load (15m): \(display(load15))")
    lines.append("Battery %: \(display(metric(rows.compactMap(\.batteryPercent))))")
    lines.append("Minimum free disk: " + (minimumDisk.map { String(format: "%.2f GiB", Double($0) / 1_073_741_824) } ?? "n/a"))
    lines.append("Window pile-up (peak): " + pile.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(10).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    var latestReview: [String: Any]?
    if let row = rows.last(where: { $0.idleReview != nil }), let suggestions = row.idleReview {
        latestReview = ["timestamp": row.timestamp, "suggestions": suggestions]
        lines.append("Idle review at \(row.timestamp)")
        lines += suggestions.isEmpty ? ["No suggestions in that sample."] : suggestions
    }
    lines += notes.map { "Note: \($0)" }
    return Output(json: ["hours": hours, "samples": rows.count, "load1m": load, "load5m": load5, "load15m": load15, "swapUsedBytes": swap, "regularApps": appCount,
                         "standardWindowsEstimate": windowCount, "batteryPercent": metric(rows.compactMap(\.batteryPercent)),
                         "tmuxSessions": metric(rows.compactMap { $0.tmuxSessions.map { Double($0) } }),
                         "minimumFreeDiskBytes": minimumDisk as Any? ?? NSNull(), "swapGrowthBytes": growth as Any? ?? NSNull(),
                         "frontmostApps": frontRows.map { ["name": $0.key, "samples": $0.value] as [String: Any] },
                         "windowPeaksByApp": pile, "memoryPressureSamples": pressure, "thermalSamples": thermal,
                         "browsers": browserRows, "latestIdleReview": latestReview as Any? ?? NSNull(), "notes": notes], text: lines.joined(separator: "\n"))
}

func readPulse(directory: URL, hours: Int, now: Date = Date()) throws -> Output {
    let cutoff = now.addingTimeInterval(-Double(hours) * 3600)
    guard FileManager.default.fileExists(atPath: directory.path) else { return pulseSummary([], hours: hours) }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    var rows: [PulseSnapshot] = [], skipped = 0
    let formatter = ISO8601DateFormatter()
    let firstMonth = String(cutoff.ISO8601Format().prefix(7)), lastMonth = String(now.ISO8601Format().prefix(7))
    for file in files where file.pathExtension == "jsonl" {
        let month = file.deletingPathExtension().lastPathComponent
        guard month >= firstMonth, month <= lastMonth else { continue }
        let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else { continue }
        let data = try Data(contentsOf: file)
        for line in data.split(separator: 10) {
            guard let row = try? JSONDecoder().decode(PulseSnapshot.self, from: Data(line)),
                  let date = formatter.date(from: row.timestamp) else { skipped += 1; continue }
            if date >= cutoff && date <= now { rows.append(row) }
        }
    }
    return pulseSummary(rows, hours: hours, skipped: skipped)
}

@MainActor
func pulse(_ args: [String]) throws -> Output {
    let parsed = try Arguments(args, values: ["--hours"])
    let verb = parsed.positionals.first ?? "report"
    guard parsed.positionals.count <= 1, ["collect", "report"].contains(verb) else { throw Failure("usage: ms pulse [collect|report [--hours N]]") }
    if verb == "collect" {
        guard parsed.options.isEmpty else { throw Failure("--hours is only supported by pulse report") }
        let row = try collectPulse()
        _ = try appendPulse(row, directory: pulseDirectory)
        let data = try JSONEncoder().encode(row)
        let json = try JSONSerialization.jsonObject(with: data)
        return Output(json: json, text: try jsonString(json))
    }
    guard let hours = Int(parsed.options["--hours"] ?? "24"), (1...8760).contains(hours) else { throw Failure("--hours must be an integer between 1 and 8760") }
    return try readPulse(directory: pulseDirectory, hours: hours)
}
