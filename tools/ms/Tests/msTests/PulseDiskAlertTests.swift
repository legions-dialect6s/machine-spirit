import Foundation
import Testing
@testable import ms

private let gib = PulseDiskReview.gibibyte
private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func disk(_ free: UInt64?, floor: UInt64 = 30) -> [PulseDiskAlert.Reading] {
    [.init(key: "startup", name: "Startup disk", freeBytes: free.map { $0 * gib }, floorBytes: floor * gib)]
}

@Test func lowDiskNotifiesOnceThenOnlyDailyOrWhenFreeSpaceHalves() {
    var state = PulseDiskAlert.State()
    var result = PulseDiskAlert.evaluate(disk(16), previous: state, now: start)
    #expect(result.notices.map(\.title) == ["Low disk space"])
    #expect(result.notices.first?.body == "Startup disk: 16.0 GiB free, below its 30.0 GiB floor.")
    state = result.state
    // The same condition an hour later, and 23 hours later, stays quiet.
    for hours in [1.0, 23.0] {
        result = PulseDiskAlert.evaluate(disk(15), previous: state, now: start.addingTimeInterval(hours * 3600))
        #expect(result.notices.isEmpty)
        #expect(result.state == state)
    }
    // Free space halved since the last notice: say so at once.
    result = PulseDiskAlert.evaluate(disk(8), previous: state, now: start.addingTimeInterval(2 * 3600))
    #expect(result.notices.count == 1)
    #expect(result.state.targets["startup"]?.lastNotifiedFreeBytes == 8 * gib)
    // Still low a day after the first notice: one reminder.
    result = PulseDiskAlert.evaluate(disk(15), previous: state, now: start.addingTimeInterval(24 * 3600))
    #expect(result.notices.count == 1)
}

@Test func recoveryNeedsHeadroomAndAnUnmountedDiskIsNotRecovered() {
    let low = PulseDiskAlert.evaluate(disk(40, floor: 50), previous: .init(), now: start).state
    // Back over the floor but inside the 10% band: still low, silent.
    var result = PulseDiskAlert.evaluate(disk(52, floor: 50), previous: low, now: start.addingTimeInterval(3600))
    #expect(result.notices.isEmpty)
    #expect(result.state == low)
    // Unmounted or unreadable: no notice, and the low state survives until it can be measured again.
    result = PulseDiskAlert.evaluate(disk(nil, floor: 50), previous: low, now: start.addingTimeInterval(3600))
    #expect(result.notices.isEmpty)
    #expect(result.state == low)
    // Remounted still low within the day: no repeat.
    result = PulseDiskAlert.evaluate(disk(41, floor: 50), previous: result.state, now: start.addingTimeInterval(7200))
    #expect(result.notices.isEmpty)
    // Measured with headroom: recovered, once.
    result = PulseDiskAlert.evaluate(disk(55, floor: 50), previous: low, now: start.addingTimeInterval(3600))
    #expect(result.notices.map(\.title) == ["Disk space recovered"])
    #expect(result.state.targets["startup"] == .init(level: .ok))
    #expect(PulseDiskAlert.evaluate(disk(56, floor: 50), previous: result.state, now: start).notices.isEmpty)
    // A disk that was never low, then disappears, then returns healthy, never notifies.
    let absent = PulseDiskAlert.evaluate(disk(nil, floor: 50), previous: .init(), now: start)
    #expect(absent.notices.isEmpty && absent.state.targets.isEmpty)
}

@Test func externalFloorsDefaultToFivePercentCappedAndHonourTheOwnersOverride() {
    #expect(PulseDiskAlert.defaultFloor(capacityBytes: 400 * gib) == 20 * gib)
    #expect(PulseDiskAlert.defaultFloor(capacityBytes: 2000 * gib) == 50 * gib)
    let id = UUID(), other = UUID(), off = UUID()
    var mounted = PulseVolumeReading(name: "Work", volumeUUID: id, status: .mounted, freeBytes: 64 * gib, capacityBytes: 1862 * gib)
    #expect(mounted.alertFloorBytes == 50 * gib)
    #expect(mounted.json["alertFloorBytes"] as? UInt64 == 50 * gib)
    mounted.configuredAlertFloorBytes = 150 * gib
    let absent = PulseVolumeReading(name: "Spare", volumeUUID: other, status: .absent)
    var disabled = PulseVolumeReading(name: "Cold", volumeUUID: off, status: .mounted, freeBytes: gib, capacityBytes: 900 * gib)
    disabled.configuredAlertFloorBytes = 0
    let review = PulseDiskReview(freeBytes: 100 * gib, capacityBytes: 460 * gib, pendingEntries: nil,
                                 externalVolumes: [mounted, absent, disabled])
    let readings = PulseDiskAlert.readings(review)
    #expect(readings.map(\.key) == ["startup", id.uuidString, other.uuidString, off.uuidString])
    #expect(readings[2].freeBytes == nil)
    let result = PulseDiskAlert.evaluate(readings, previous: .init(), now: start)
    #expect(result.notices.map(\.body) == ["Work: 64.0 GiB free, below its 150.0 GiB floor."])
    #expect(result.state.targets[off.uuidString] == nil)
    #expect(review.output.text.contains("alert floor: 150.0 GiB"))
    #expect(review.output.text.contains("alerts off"))
}

@Test func volumeConfigurationValidatesAlertFloors() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("volumes.json")
    let id = UUID().uuidString
    try Data(#"[{"name":"Work","volumeUUID":"\#(id)","alertFloorGiB":150}]"#.utf8).write(to: config)
    #expect(try PulseVolumeTarget.configured(at: config).first?.alertFloorGiB == 150)
    try Data(#"[{"name":"Work","volumeUUID":"\#(id)","alertFloorGiB":-1}]"#.utf8).write(to: config)
    #expect(throws: Failure.self) { try PulseVolumeTarget.configured(at: config) }
}

@Test func alertRunPersistsStateAndRetriesAnUndeliveredNotice() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let review = PulseDiskReview(freeBytes: 16 * gib, capacityBytes: 460 * gib, pendingEntries: nil)
    var delivered: [PulseDiskAlert.Notice] = []
    // Delivery fails: nothing is recorded as sent, so the next sample tries again.
    var result = PulseDiskAlert.run(review, directory: directory, now: start) { _ in false }
    #expect((result["failed"] as? [[String: String]])?.count == 1)
    #expect(PulseDiskAlert.load(from: directory) == .init())
    result = PulseDiskAlert.run(review, directory: directory, now: start.addingTimeInterval(3600)) { delivered.append($0); return true }
    #expect(delivered.count == 1)
    #expect(result["low"] as? [String] == ["startup"])
    let file = directory.appendingPathComponent(PulseDiskAlert.stateFileName)
    let mode = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
    #expect(mode == 0o600)
    #expect(PulseDiskAlert.load(from: directory).targets["startup"]?.level == .low)
    // The next hourly sample with the same condition is silent.
    _ = PulseDiskAlert.run(review, directory: directory, now: start.addingTimeInterval(7200)) { delivered.append($0); return true }
    #expect(delivered.count == 1)
    // A symlinked state file is ignored rather than followed.
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("elsewhere"))
    #expect(PulseDiskAlert.load(from: directory) == .init())
}

@MainActor @Test func alertFlagBelongsToCollectOnly() {
    #expect(throws: Failure.self) { try pulse(["report", "--alert"]) }
    #expect(throws: Failure.self) { try pulse(["disk", "--alert"]) }
    #expect(throws: Failure.self) { try pulse(["collect", "--explain"]) }
}
