import Darwin
import Foundation
import Testing
@testable import ms

private struct ProjectFixture {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let volume = UUID()
    let now = ISO8601DateFormatter().date(from: "2026-11-22T12:00:00Z")!
    var folder: URL { root.appendingPathComponent("project-previews") }
    var file: URL { folder.appendingPathComponent("example-project.json") }
    var row: [String: Any] { ["id": "merged", "label": "Merged packages", "bytes": 4096, "itemCount": 1, "safeReason": "Project lease check passed."] }
    var ok: [String: Any] {
        ["schemaVersion": 1, "providerId": "example-project", "volumeUUID": volume.uuidString, "generatedAt": "2026-11-22T12:00:00Z",
         "status": "ok", "reclaimableBytes": 4096, "categories": [row]]
    }

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    func write(_ json: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func read(_ state: PulseVolumeReading.Status = .mounted) -> ProjectDiskPreview {
        ProjectDiskPreview.read(directory: root, provider: "example-project", expectedVolume: volume,
                                volumes: [PulseVolumeReading(name: "Work", volumeUUID: volume, status: state)], now: now)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func projectPreviewReturnsOnlyValidatedAggregates() throws {
    let f = try ProjectFixture()
    defer { f.remove() }
    var doc = f.ok
    var category = f.row
    category["paths"] = ["excluded"]
    doc["categories"] = [category]
    doc["internal"] = "excluded"
    doc["generatedAt"] = "2026-11-22T11:59:59.123456+00:00"
    try f.write(doc)
    let result = f.read()
    #expect(result.status == "ok")
    #expect(result.reclaimableBytes == 4096)
    #expect(result.json["internal"] == nil)
    #expect((result.json["categories"] as? [[String: Any]])?.first?["paths"] == nil)
    #expect(result.summary.contains("4096"))
    doc["reclaimableBytes"] = 0
    doc["categories"] = []
    try f.write(doc)
    #expect(f.read().reclaimableBytes == 0)
}

@Test func projectPreviewRejectsWrongVolumeOrProviderAndDoesNotCache() throws {
    let f = try ProjectFixture()
    defer { f.remove() }
    #expect(f.read().reclaimableBytes == nil)
    try f.write(f.ok)
    #expect(f.read().status == "ok")
    for state in [PulseVolumeReading.Status.absent, .unavailable, .differentVolume] {
        #expect(f.read(state).status == "unavailable")
    }
    for (key, value) in [("volumeUUID", UUID().uuidString), ("providerId", "other")] {
        var doc = f.ok
        doc[key] = value
        try f.write(doc)
        #expect(f.read().json["reclaimableBytes"] is NSNull)
    }
    try FileManager.default.removeItem(at: f.file)
    #expect(f.read().status == "unavailable")
}

@Test func projectPreviewValidatesFreshnessBothDirections() throws {
    let f = try ProjectFixture()
    defer { f.remove() }
    for (timestamp, accepted) in [("2026-11-22T11:45:00Z", true), ("2026-11-22T11:44:59.999Z", false),
                                  ("2026-11-22T12:01:00+00:00", true), ("2026-11-22T12:01:00.001Z", false),
                                  ("2026-11-22T04:00:00-08:00", false), ("2026-11-22 12:00:00", false),
                                  ("2026-11-31T12:00:00Z", false)] {
        var doc = f.ok
        doc["generatedAt"] = timestamp
        try f.write(doc)
        #expect((f.read().status == "ok") == accepted)
    }
}

@Test func projectPreviewRejectsInconsistentTotalsAndStatuses() throws {
    let f = try ProjectFixture()
    defer { f.remove() }
    var blocked = f.ok
    blocked["categories"] = []
    blocked["reclaimableBytes"] = NSNull()
    for state in ["blocked", "unavailable"] {
        blocked["status"] = state
        blocked["reason"] = "Project scan is busy."
        try f.write(blocked)
        #expect(f.read().status == state)
        #expect(f.read().json["reason"] as? String == "Project scan is busy.")
    }
    blocked.removeValue(forKey: "reclaimableBytes")
    try f.write(blocked)
    #expect(f.read().json["generatedAt"] == nil)
    blocked["reclaimableBytes"] = NSNull()
    blocked["reason"] = "  "
    try f.write(blocked)
    #expect(f.read().json["generatedAt"] == nil)

    for (key, value): (String, Any) in [("categories", [f.row, f.row]), ("reclaimableBytes", 15), ("reclaimableBytes", -1),
                                        ("schemaVersion", true), ("status", "failed")] {
        var bad = f.ok
        bad[key] = value
        try f.write(bad)
        #expect(f.read().status == "unavailable")
    }
    for badValue: Any in [true, -1, 0.5, "1"] {
        var row = f.row
        row["itemCount"] = badValue
        var bad = f.ok
        bad["categories"] = [row]
        try f.write(bad)
        #expect(f.read().status == "unavailable")
    }
    var large = f.row, second = f.row
    large["bytes"] = UInt64.max
    second["bytes"] = 1
    second["id"] = "other"
    var overflow = f.ok
    overflow["categories"] = [large, second]
    overflow["reclaimableBytes"] = 0
    try f.write(overflow)
    #expect(f.read().status == "unavailable")
}

@Test func projectPreviewRejectsSymlinksPermissionsFIFOsAndOversizedSnapshots() throws {
    let f = try ProjectFixture()
    defer { f.remove() }
    let fm = FileManager.default
    try f.write(f.ok)
    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.file.path)
    #expect(f.read().status == "unavailable")
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.file.path)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.folder.path)
    #expect(f.read().status == "unavailable")
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.folder.path)
    let real = f.root.appendingPathComponent("real")
    try fm.moveItem(at: f.folder, to: real)
    try fm.createSymbolicLink(at: f.folder, withDestinationURL: real)
    #expect(f.read().status == "unavailable")
    try fm.removeItem(at: f.folder)
    try fm.moveItem(at: real, to: f.folder)
    try fm.moveItem(at: f.file, to: real)
    try fm.createSymbolicLink(at: f.file, withDestinationURL: real)
    #expect(f.read().status == "unavailable")
    try fm.removeItem(at: f.file)
    #expect(mkfifo(f.file.path, 0o600) == 0)
    #expect(f.read().status == "unavailable")
    try fm.removeItem(at: f.file)
    var data = try Data(contentsOf: real)
    data.append(Data(repeating: 32, count: 65536 - data.count))
    try data.write(to: f.file)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.file.path)
    #expect(f.read().status == "ok")
    data.append(32)
    try data.write(to: f.file)
    #expect(f.read().status == "unavailable")
    try Data("{".utf8).write(to: f.file)
    #expect(f.read().status == "unavailable")
}
