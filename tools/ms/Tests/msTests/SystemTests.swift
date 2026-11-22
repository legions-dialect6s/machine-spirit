import Foundation
import Testing
@testable import ms

@Test func browserAggregationKeepsOnlyDomainsAndCountsExtraDuplicates() throws {
    let row = pulseBrowser("Safari", urls: ["https://example.org/a?q=private", "https://example.org/a?q=private", "https://example.org/b", "about:blank", "", "file:///private/secret"])
    #expect(row.tabs == 6)
    #expect(row.duplicateTabs == 1)
    #expect(row.topDomains == [PulseDomain(domain: "example.org", count: 3)])
    let encoded = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
    #expect(!encoded.contains("private"))
    #expect(!encoded.contains("secret"))
}

private func sample(_ timestamp: String, tabs: Int? = nil) -> PulseSnapshot {
    PulseSnapshot(timestamp: timestamp, uptimeSeconds: 100, loadAverages: [1, 2, 3], memoryPressure: "normal",
                  swapUsedBytes: 10, freeDiskBytes: 100_000_000_000, batteryPercent: nil, batteryCycles: nil,
                  batteryHealth: nil, thermalState: "nominal", frontmostApp: "Finder", regularAppCount: 1,
                  apps: [PulseApp(name: "Finder", bundleId: "com.apple.finder", pid: 1, standardWindowsEstimate: 3, offScreenWindows: 2)],
                  browsers: [PulseBrowser(name: "Safari", status: tabs == nil ? "unavailable" : "ok", tabs: tabs, duplicateTabs: tabs == nil ? nil : 1)],
                  tmuxSessions: nil, notes: [])
}

@Test func reportExcludesUnknownsAndDoesNotInventTrends() throws {
    let output = pulseSummary([sample("2026-01-01T01:00:00Z", tabs: 12), sample("2026-01-01T02:00:00Z")], hours: 24)
    let json = try #require(output.json as? [String: Any])
    let swap = try #require(json["swapUsedBytes"] as? [String: Any])
    #expect(swap["average"] as? Double == 10)
    #expect(swap["peak"] as? Double == 10)
    let browsers = try #require(json["browsers"] as? [[String: Any]])
    let tabs = try #require(browsers[0]["tabs"] as? [String: Any])
    #expect(tabs["average"] as? Double == 12)
    #expect(tabs["samples"] as? Int == 1)
    #expect(browsers[0]["tabChange"] is NSNull)
    #expect(browsers[0]["unavailableSamples"] as? Int == 1)
    let appData = try JSONEncoder().encode(sample("2026-01-01T00:00:00Z").apps[0])
    let app = try #require(JSONSerialization.jsonObject(with: appData) as? [String: Any])
    #expect(app["minimizedWindows"] is NSNull)
}

@Test func pulseLogsCrossMonthsFilterDatesAndRejectSymlinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try appendPulse(sample("2026-01-31T23:00:00Z", tabs: 5), directory: directory)
    let feb = try appendPulse(sample("2026-02-01T01:00:00Z", tabs: 9), directory: directory)
    _ = try appendPulse(sample("2026-02-01T03:00:00Z", tabs: 99), directory: directory)
    let file = try FileHandle(forWritingTo: feb)
    try file.seekToEnd(); try file.write(contentsOf: Data("incomplete\n".utf8)); try file.close()
    let now = try #require(ISO8601DateFormatter().date(from: "2026-02-01T02:00:00Z"))
    let output = try readPulse(directory: directory, hours: 4, now: now)
    let json = try #require(output.json as? [String: Any])
    #expect(json["samples"] as? Int == 2)
    #expect(output.text.contains("Skipped 1"))
    let mode = try FileManager.default.attributesOfItem(atPath: feb.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    let march = directory.appendingPathComponent("2026-03.jsonl")
    try FileManager.default.createSymbolicLink(at: march, withDestinationURL: feb)
    #expect(throws: Failure.self) { try appendPulse(sample("2026-03-01T00:00:00Z"), directory: directory) }
}

@Test func idleReviewReusesObservationsAndReadsPreviousLogs() throws {
    let old = sample("2026-01-01T00:00:00Z", tabs: 4)
    let legacy = try JSONDecoder().decode(PulseSnapshot.self, from: JSONEncoder().encode(old))
    #expect(legacy.idleReview == nil)
    #expect(idleReview(after: 599, browsers: old.browsers, apps: old.apps) == nil)
    #expect(idleReview(after: .infinity, browsers: old.browsers, apps: old.apps) == nil)
    var idle = sample("2026-01-01T01:00:00Z", tabs: 4)
    idle.idleReview = idleReview(after: 600, browsers: idle.browsers, apps: idle.apps)
    #expect(idle.idleReview?.count == 2)
    #expect(idleReview(after: 600, browsers: [PulseBrowser(name: "Safari", status: "unavailable")], apps: []) == [])
    let later = sample("2026-01-01T02:00:00Z")
    let report = pulseSummary([later, idle, old], hours: 24)
    let json = try #require(report.json as? [String: Any])
    let review = try #require(json["latestIdleReview"] as? [String: Any])
    #expect(review["timestamp"] as? String == idle.timestamp)
    #expect(review["suggestions"] as? [String] == idle.idleReview)
}

@Test func timedOutChildIsReaped() {
    let child = PulseChild("/bin/sleep", ["5"])
    PulseChild.finish([child], deadline: ProcessInfo.processInfo.systemUptime + 0.02)
    #expect(!child.task.isRunning)
    #expect(child.output == nil)
    #expect(child.failure != nil)
}

@Test func systemToolSchemasAndRouting() throws {
    let specs = toolSpecs(allowClipboard: false)
    let report = try #require(specs.first { $0.name == "pulse_report" })
    #expect(report.readOnly)
    #expect(throws: Failure.self) { try report.validate(["hours": 0]) }
    #expect(throws: Failure.self) { try report.validate(["hours": true]) }
    #expect(try toolArguments("pulse_report", ["hours": 48]) == ["report", "--hours", "48"])
    #expect(try toolArguments("audio_list", [:]) == ["list"])
}

@Test @MainActor func systemCommandsRejectInvalidArgumentsBeforeSideEffects() async throws {
    #expect(throws: Failure.self) { try capslock(["invalid"]) }
    #expect(throws: Failure.self) { try audio(["list", "extra"]) }
    #expect(throws: Failure.self) { try pulse(["collect", "--hours", "1"]) }
    #expect(throws: Failure.self) { try pulse(["report", "--hours", "0"]) }
    #expect(throws: Failure.self) { try pulse(["report", "--hours", "nan"]) }
    await #expect(throws: Failure.self) { _ = try await translateArea(["--to", "bad?target", "--image", "/does-not-exist"]) }
}
