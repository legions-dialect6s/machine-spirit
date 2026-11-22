import Foundation
import Testing
@testable import ms

@Test func diskBaselineUsesOnlyRecentCompleteSamplesAcrossMonths() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let lastMonth = root.appendingPathComponent("2026-10.jsonl")
    let thisMonth = root.appendingPathComponent("2026-11.jsonl")
    let prior = #"{"timestamp":"2026-10-31T23:59:59Z","freeDiskBytes":30}"# + "\n"
    let now = try #require(ISO8601DateFormatter().date(from: "2026-11-01T00:01:00Z"))
    try Data(prior.utf8).write(to: lastMonth)
    let incomplete = #"{"timestamp":"2026-11-01T00:00:01Z","freeDiskBytes":999}"#
    try Data(incomplete.utf8).write(to: thisMonth)
    #expect(PulseDiskBaseline.latest(in: root, now: now)?.freeDiskBytes == 30)
    let latest = incomplete + "\n" + #"{"timestamp":"2026-11-01T00:30:00Z","freeDiskBytes":987}"# + "\n"
    try Data(latest.utf8).write(to: thisMonth)
    #expect(PulseDiskBaseline.latest(in: root, now: now)?.freeDiskBytes == 999)
    #expect(PulseDiskBaseline.latest(in: root, now: now.addingTimeInterval(90_000)) == nil)
    #expect(PulseDiskBaseline.delta(from: 999, to: 900) == -99)
    #expect(PulseDiskBaseline.delta(from: nil, to: 0) == nil)
}

@Test func providerBindingsRejectAmbiguityAndUntrustedConfig() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("volumes.json")
    let target = PulseVolumeTarget(name: "Work", volumeUUID: UUID(), projectProvider: "example-project")
    let other = PulseVolumeTarget(name: "Second", volumeUUID: UUID(), projectProvider: "example-project")
    try JSONEncoder().encode([target, other]).write(to: config)
    #expect(throws: Failure.self) { try PulseVolumeTarget.configured(at: config) }
    for invalid in ["../other", "", "project/secret"] {
        let unsafe = PulseVolumeTarget(name: "Work", volumeUUID: UUID(), projectProvider: invalid)
        try JSONEncoder().encode([unsafe]).write(to: config)
        #expect(throws: Failure.self) { try PulseVolumeTarget.configured(at: config) }
    }
    try JSONEncoder().encode([target]).write(to: config)
    #expect(try PulseVolumeTarget.configured(at: config).first?.projectProvider == target.projectProvider)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: config)
    #expect(throws: Failure.self) { try PulseVolumeTarget.configured(at: alias) }
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: config.path)
    #expect(throws: Failure.self) { try PulseVolumeTarget.configured(at: config) }
}

@Test @MainActor func explainIsExplicitAndExclusive() async {
    await #expect(throws: Failure.self) { _ = try await pulseCLI(["collect", "--explain"]) }
    await #expect(throws: Failure.self) { _ = try await pulseCLI(["report", "--explain"]) }
    await #expect(throws: Failure.self) { _ = try await pulseCLI(["disk", "--explain", "--crash-preview"]) }
    await #expect(throws: Failure.self) { _ = try await pulseCLI(["disk", "--hours", "2", "--explain"]) }
}
