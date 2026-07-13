import Foundation
import Testing

@testable import MachineSpiritKit

/// The pen's grammar, proven pure: every edit returns a new tree, refuses
/// loudly, and mints ids exactly as the importer would on re-import.
struct NodeEditingTests {
  let importer = LeaderKeyImporter(probe: RoundTripTests.FakeProbe(everythingPresent: true))

  private let seed = #"""
    {"type":"group","actions":[
      {"key":"a","type":"application","value":"/Applications/Alpha.app"},
      {"key":"g","type":"group","actions":[
        {"key":"x","type":"command","value":"echo x"}
      ]},
      {"key":"e","type":"group"}
    ]}
    """#

  private func seededModel() throws -> Node {
    try importer.importConfig(from: Data(seed.utf8))
  }

  @Test func insertMintsTheImportersID() throws {
    let model = try seededModel()
    let next = try model.insertingLeaf(
      key: "n", label: "new", action: .command("echo n"), underGroupID: "root/g")
    let inserted = try #require(next.node(withID: "root/g/n"))
    #expect(inserted.key == "n")
    #expect(inserted.label == "new")
    #expect(inserted.action == .command("echo n"))
    // The original tree is untouched (value semantics).
    #expect(model.node(withID: "root/g/n") == nil)
    // Round-trip: what re-import mints must equal what the pen minted.
    let reimported = try importer.importConfig(from: LeaderKeySerializer.data(from: next))
    #expect(reimported.node(withID: "root/g/n")?.key == "n")
    #expect(reimported.node(withID: "root/g/n")?.action == .command("echo n"))
  }

  @Test func insertUnderRootAndUnderChildlessGroup() throws {
    let model = try seededModel()
    let atRoot = try model.insertingLeaf(
      key: "z", action: .url("https://example.com"), underGroupID: "root")
    #expect(atRoot.node(withID: "root/z")?.action == .url("https://example.com"))

    // "e" is a declared group with NO actions array — inserting must grow
    // one, and the result must still round-trip cleanly.
    let atEmpty = try model.insertingLeaf(
      key: "q", action: .application(path: "/Applications/Q.app"), underGroupID: "root/e")
    let reimported = try importer.importConfig(from: LeaderKeySerializer.data(from: atEmpty))
    #expect(reimported.node(withID: "root/e/q") != nil)
  }

  @Test func insertRefusals() throws {
    let model = try seededModel()
    #expect(throws: EditError.parentNotFound("root/zzz")) {
      try model.insertingLeaf(key: "n", action: .command("x"), underGroupID: "root/zzz")
    }
    #expect(throws: EditError.parentHasAction("root/a")) {
      try model.insertingLeaf(key: "n", action: .command("x"), underGroupID: "root/a")
    }
    #expect(throws: EditError.duplicateKey(key: "x", parentID: "root/g")) {
      try model.insertingLeaf(key: "x", action: .command("x"), underGroupID: "root/g")
    }
  }

  @Test func emptyLabelBecomesNil() throws {
    let model = try seededModel()
    let next = try model.insertingLeaf(
      key: "n", label: "", action: .command("echo n"), underGroupID: "root/g")
    #expect(next.node(withID: "root/g/n")?.label == nil)
  }

  @Test func removeStrikesOnlyTheTarget() throws {
    let model = try seededModel()
    let next = try model.removingLeaf(id: "root/g/x")
    #expect(next.node(withID: "root/g/x") == nil)
    // Everything else stands — most importantly SIBLING SUBTREES of the
    // ancestors along the removal path.
    #expect(next.node(withID: "root/a") != nil)
    #expect(next.node(withID: "root/g") != nil)
    #expect(next.node(withID: "root/e") != nil)
    #expect(model.node(withID: "root/g/x") != nil)  // original untouched
  }

  @Test func removeRefusals() throws {
    let model = try seededModel()
    #expect(throws: EditError.rootUntouchable) {
      try model.removingLeaf(id: "root")
    }
    #expect(throws: EditError.nodeNotFound("root/zzz")) {
      try model.removingLeaf(id: "root/zzz")
    }
    #expect(throws: EditError.notALeaf("root/g")) {
      try model.removingLeaf(id: "root/g")
    }
  }

  /// The whole 6b ritual, headless: seed a target file, add a leaf through
  /// the writer, remove it through the writer, and land back at canonical
  /// equality with where we started — two writes, two backups, zero drift.
  @Test func addThenRemoveThroughTheWriterRoundTrips() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("pen-ritual-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("config.json")
    try Data(seed.utf8).write(to: target)

    let writer = ConfigWriter(
      probe: RoundTripTests.FakeProbe(everythingPresent: true),
      backupDirectory: dir.appendingPathComponent("backups", isDirectory: true))

    let original = try importer.importConfig(at: target)
    let added = try original.insertingLeaf(
      key: "n", label: "pen test", action: .command("echo n"), underGroupID: "root/g")
    let addReport = try writer.write(added, to: target)
    #expect(addReport.summary == ["+ root/g/n"])

    let afterAdd = try importer.importConfig(at: target)
    #expect(afterAdd.node(withID: "root/g/n")?.label == "pen test")

    let removed = try afterAdd.removingLeaf(id: "root/g/n")
    let removeReport = try writer.write(removed, to: target)
    #expect(removeReport.summary == ["− root/g/n"])

    let final = try importer.importConfig(at: target)
    #expect(
      LeaderKeySerializer.jsonValue(from: final) == LeaderKeySerializer.jsonValue(from: original))
  }

  /// The same ritual against a COPY of the real live config — the pen's
  /// exact code path over the owner's actual 150-odd nodes. The live file
  /// itself is read once and never written; skips when absent (CI).
  @Test func penRitualOnALiveConfigCopy() throws {
    let live = LeaderKeyImporter.liveConfigURL
    guard FileManager.default.fileExists(atPath: live.path) else { return }
    let liveBytes = try Data(contentsOf: live)

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("pen-live-copy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("config.json")
    try liveBytes.write(to: target)

    let realProbeImporter = LeaderKeyImporter()
    let writer = ConfigWriter(
      backupDirectory: dir.appendingPathComponent("backups", isDirectory: true))

    let original = try realProbeImporter.importConfig(at: target)
    let freeKey = try #require(
      "0123456789".map(String.init).first { key in
        !original.children.contains { $0.key == key }
      })

    let added = try original.insertingLeaf(
      key: freeKey, label: "pen ritual", action: .command("echo pen"),
      underGroupID: "root")
    #expect(try writer.write(added, to: target).summary == ["+ root/\(freeKey)"])

    let removed = try realProbeImporter.importConfig(at: target)
      .removingLeaf(id: "root/\(freeKey)")
    #expect(try writer.write(removed, to: target).summary == ["− root/\(freeKey)"])

    let final = try realProbeImporter.importConfig(at: target)
    #expect(
      LeaderKeySerializer.jsonValue(from: final) == LeaderKeySerializer.jsonValue(from: original))
    #expect(try Data(contentsOf: live) == liveBytes)  // the live file: untouched
  }
}
