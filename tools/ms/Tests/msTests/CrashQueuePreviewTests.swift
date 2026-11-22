import Darwin
import Foundation
import Testing
@testable import ms

@Test func crashPreviewPairsMetadataAndSkipsRecentOrUntrustedFiles() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
    let now = cutoff.addingTimeInterval(7 * 86_400)
    let old = cutoff.addingTimeInterval(-60)
    func stem() -> String { UUID().uuidString.lowercased() }
    @discardableResult
    func make(_ name: String, at date: Date) throws -> URL {
        let file = root.appendingPathComponent(name)
        try Data(repeating: 42, count: 15_000).write(to: file)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        return file
    }
    let eligible = stem(), recent = stem(), lonely = stem(), symlink = stem(), hardlink = stem()
    let dump = try make(eligible + ".dmp", at: old)
    let sidecar = try make(eligible + "_sidecar.json", at: old)
    try make(recent + ".dmp", at: old)
    try make(recent + "_sidecar.json", at: cutoff)
    try make(lonely + ".dmp", at: old)
    try make("unknown_sidecar.json", at: old)
    try make(symlink + "_sidecar.json", at: old)
    try fm.createSymbolicLink(at: root.appendingPathComponent(symlink + ".dmp"), withDestinationURL: dump)
    let linked = try make(hardlink + ".dmp", at: old)
    try fm.linkItem(at: linked, to: root.appendingPathComponent(hardlink + "_sidecar.json"))
    let before = try Set(fm.contentsOfDirectory(atPath: root.path))

    let preview = try CrashQueuePreview.read(at: root, now: now)
    var dumpInfo = stat(), sidecarInfo = stat()
    #expect(lstat(dump.path, &dumpInfo) == 0)
    #expect(lstat(sidecar.path, &sidecarInfo) == 0)
    #expect(preview.eligiblePairs == 1)
    #expect(preview.eligibleAllocatedBytes == UInt64(dumpInfo.st_blocks + sidecarInfo.st_blocks) * 512)
    #expect(preview.recentPairs == 1)
    #expect(preview.unpairedEntries == 1)
    #expect(preview.unrecognizedEntries == 1)
    #expect(preview.unsafeOrChangedPairs == 2)
    #expect(preview.oldestPairAt == old)
    #expect(preview.newestPairAt == cutoff)
    #expect(try Set(fm.contentsOfDirectory(atPath: root.path)) == before)
    #expect(try Data(contentsOf: dump) == Data(repeating: 42, count: 15_000))
    #expect(try Data(contentsOf: sidecar) == Data(repeating: 42, count: 15_000))
}

@Test func crashPreviewRefusesSymlinkedParentsAndMissingQueue() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
    let actual = root.appendingPathComponent("actual")
    let link = root.appendingPathComponent("link")
    try fm.createDirectory(at: actual.appendingPathComponent("pending"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createSymbolicLink(at: link, withDestinationURL: actual)
    #expect(throws: Failure.self) { try CrashQueuePreview.read(at: link.appendingPathComponent("pending")) }
    #expect(throws: Failure.self) { try CrashQueuePreview.read(at: root.appendingPathComponent("absent")) }
    let empty = try CrashQueuePreview.read(at: actual.appendingPathComponent("pending"))
    #expect(empty.eligiblePairs == 0)
    #expect(empty.oldestPairAt == nil)
}

@Test @MainActor func crashPreviewFlagRequiresExplicitDiskCommand() throws {
    #expect(throws: Failure.self) { try pulse(["collect", "--crash-preview"]) }
    #expect(throws: Failure.self) { try pulse(["report", "--crash-preview"]) }
    #expect(throws: Failure.self) { try pulse(["disk", "--crash-preview", "--hours", "8"]) }
}
