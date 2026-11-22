import Foundation
import Testing
@testable import ms

@Test func volumeConfigurationIsOptInAndRejectsAmbiguousPathsAndIDs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("volumes.json")
    #expect(try PulseVolumeTarget.configured(at: config).isEmpty)
    let volume = PulseVolumeTarget(name: "Work", volumeUUID: UUID())
    try JSONEncoder().encode([volume]).write(to: config)
    #expect(try PulseVolumeTarget.configured(at: config).first?.volumeUUID == volume.volumeUUID)
    for extra in [PulseVolumeTarget(name: "../Work", volumeUUID: UUID()), .init(name: "Work", volumeUUID: UUID()),
                  .init(name: "Spare", volumeUUID: volume.volumeUUID)] {
        try JSONEncoder().encode([volume, extra]).write(to: config)
        #expect(throws: Failure.self) { try PulseVolumeTarget.configured(at: config) }
    }
}

@Test func absentVolumeNeverReportsCapacityOfItsParent() throws {
    let target = PulseVolumeTarget(name: UUID().uuidString, volumeUUID: UUID())
    let reading = try #require(PulseVolumeReading.read([target], refresh: true).first)
    #expect(reading.status == .absent)
    #expect(reading.freeBytes == nil)
    #expect(reading.capacityBytes == nil)
}

@Test func externalVolumeHistoryGroupsByIdentityAndPreservesDisconnects() throws {
    let a = UUID(), b = UUID()
    func sample(_ hour: Int, _ id: UUID, _ status: PulseVolumeReading.Status, _ free: UInt64?) -> PulseSnapshot {
        let reading = PulseVolumeReading(name: "Work", volumeUUID: id, status: status, freeBytes: free)
        return PulseSnapshot(timestamp: "2026-11-22T0\(hour):00:00Z", uptimeSeconds: 1, loadAverages: [],
                             memoryPressure: "normal", swapUsedBytes: nil, freeDiskBytes: nil, batteryPercent: nil,
                             batteryCycles: nil, batteryHealth: nil, thermalState: "nominal", frontmostApp: nil,
                             regularAppCount: 0, apps: [], browsers: [], tmuxSessions: nil, notes: [], externalVolumes: [reading])
    }
    let report = pulseSummary([sample(5,b,.mounted,9000),sample(4,a,.absent,nil),sample(3,a,.mounted,60),
                               sample(2,a,.differentVolume,nil),sample(1,a,.mounted,100)], hours: 6)
    let json = try #require(report.json as? [String: Any])
    let volumes = try #require(json["externalVolumes"] as? [[String: Any]])
    #expect(volumes.count == 2)
    let first = try #require(volumes.first { $0["volumeUUID"] as? String == a.uuidString })
    #expect(first["status"] as? String == "absent")
    #expect(first["freeBytes"] is NSNull)
    #expect(first["measuredSamples"] as? Int == 2)
    #expect(first["unavailableSamples"] as? Int == 2)
    #expect(first["latestMeasuredFreeBytes"] as? UInt64 == 60)
    #expect(first["freeDiskChangeBytes"] as? Double == -40)
    let second = try #require(volumes.first { $0["volumeUUID"] as? String == b.uuidString })
    #expect(second["freeDiskChangeBytes"] is NSNull)
}
@Test func externalVolumeSuggestionsUseTenPercentOfCapacity() {
    let gib = PulseDiskReview.gibibyte
    var volume = PulseVolumeReading(name: "Archive", volumeUUID: UUID(), status: .mounted,
                                    freeBytes: 64 * gib, capacityBytes: 1024 * gib)
    var review = PulseDiskReview(freeBytes: nil, capacityBytes: nil, pendingEntries: nil, externalVolumes: [volume])
    #expect(volume.json["reviewThresholdBytes"] as? UInt64 == 1024 * gib / 10)
    #expect(review.suggestions.count == 1)
    volume.freeBytes = volume.reviewThresholdBytes
    review.externalVolumes = [volume]
    #expect(review.suggestions.isEmpty)
}
