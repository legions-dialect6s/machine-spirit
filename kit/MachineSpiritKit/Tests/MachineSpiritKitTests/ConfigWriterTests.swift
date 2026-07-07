import Foundation
import Testing

@testable import MachineSpiritKit

/// The write ritual, proven against temp targets only — these tests never
/// touch the live config, the real backup directory, or anything outside
/// their own scratch folder.
struct ConfigWriterTests {
  let dir: URL
  let target: URL
  let backups: URL
  let importer = LeaderKeyImporter(probe: RoundTripTests.FakeProbe(everythingPresent: true))

  init() throws {
    dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("writer-tests-\(UUID().uuidString)", isDirectory: true)
    backups = dir.appendingPathComponent("backups", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    target = dir.appendingPathComponent("config.json")
  }

  private func writer(
    serialize: (@Sendable (Node) throws -> Data)? = nil
  ) -> ConfigWriter {
    ConfigWriter(
      probe: RoundTripTests.FakeProbe(everythingPresent: true),
      serialize: serialize ?? { try LeaderKeySerializer.data(from: $0) },
      backupDirectory: backups)
  }

  private func seedTarget(_ json: String) throws {
    try Data(json.utf8).write(to: target)
  }

  private let seed = #"""
    {"type":"group","actions":[
      {"key":"a","type":"application","value":"/Applications/Alpha.app"},
      {"key":"g","type":"group","actions":[
        {"key":"x","type":"command","value":"echo x"}
      ]}
    ]}
    """#

  private func seededModel() throws -> Node {
    try seedTarget(seed)
    return try importer.importConfig(at: target)
  }

  @Test func happyPathWritesBacksUpAndReports() throws {
    var model = try seededModel()
    // Add a leaf under the "g" group, drop the "a" bind.
    var group = model.children[1]
    group.children.append(
      Node(
        id: "root/g/n", key: "n", label: "new",
        action: .from(type: "command", value: "echo n"),
        children: [], extras: [:], status: .active,
        hadExplicitType: true, hadChildrenArray: false))
    model.children = [group]

    let originalBytes = try Data(contentsOf: target)
    let report = try writer().write(model, to: target)

    // Backup holds the PRE-write bytes exactly.
    #expect(try Data(contentsOf: URL(fileURLWithPath: report.backupPath)) == originalBytes)
    // The target now re-imports to the intended model, canonically.
    let after = try importer.importConfig(at: target)
    #expect(
      LeaderKeySerializer.jsonValue(from: after) == LeaderKeySerializer.jsonValue(from: model))
    // Node-level summary: the removal and the addition, nothing invented.
    #expect(report.summary.contains("− root/a"))
    #expect(report.summary.contains("+ root/g/n"))
    // No temp debris beside the target.
    let debris = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0.contains(".ms-tmp-") }
    #expect(debris.isEmpty)
  }

  @Test func redGateRefusesAndLeavesTargetUntouched() throws {
    // Duplicate keys cannot round-trip through the model — the gate must
    // refuse rather than let a write silently drop one.
    try seedTarget(#"{"type":"group","type":"group","actions":[]}"#)
    let before = try Data(contentsOf: target)
    let model = Node(
      id: "root", key: nil, label: nil, action: nil, children: [], extras: [:],
      status: .active, hadExplicitType: true, hadChildrenArray: true)

    #expect(throws: WriteError.self) {
      try writer().write(model, to: target)
    }
    #expect(try Data(contentsOf: target) == before)
    // A red gate also never creates a backup directory.
    #expect(!FileManager.default.fileExists(atPath: backups.path))
  }

  @Test func missingTargetRefuses() throws {
    let model = Node(
      id: "root", key: nil, label: nil, action: nil, children: [], extras: [:],
      status: .active, hadExplicitType: true, hadChildrenArray: true)
    #expect(throws: WriteError.self) {
      try writer().write(model, to: target)
    }
  }

  @Test func corruptedSerializeIsCaughtBeforeTheTarget() throws {
    let model = try seededModel()
    let before = try Data(contentsOf: target)

    // Fault 1: the serializer emits garbage bytes.
    #expect(throws: WriteError.self) {
      try writer(serialize: { _ in Data("{not json".utf8) }).write(model, to: target)
    }
    #expect(try Data(contentsOf: target) == before)

    // Fault 2: valid JSON, wrong content — the subtler lie.
    #expect(throws: WriteError.self) {
      try writer(serialize: { _ in Data(#"{"type":"group","actions":[]}"#.utf8) })
        .write(model, to: target)
    }
    #expect(try Data(contentsOf: target) == before)

    // Neither fault left temp debris.
    let debris = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0.contains(".ms-tmp-") }
    #expect(debris.isEmpty)
  }

  @Test func unchangedModelWritesCleanlyWithEmptySummary() throws {
    let model = try seededModel()
    let report = try writer().write(model, to: target)
    #expect(report.summary.isEmpty)
    let after = try importer.importConfig(at: target)
    #expect(
      LeaderKeySerializer.jsonValue(from: after) == LeaderKeySerializer.jsonValue(from: model))
  }

  /// The whole ritual against a COPY of the real live config, when this
  /// machine has one (self-skipping elsewhere). The live file itself is
  /// read once and never written — the target is the temp copy.
  @Test func liveConfigCopySurvivesTheFullRitual() throws {
    let live = LeaderKeyImporter.liveConfigURL
    guard FileManager.default.fileExists(atPath: live.path) else { return }
    let liveBytes = try Data(contentsOf: live)
    try liveBytes.write(to: target)

    let model = try importer.importConfig(at: target)
    let report = try writer().write(model, to: target)

    #expect(report.summary.isEmpty)
    #expect(try Data(contentsOf: URL(fileURLWithPath: report.backupPath)) == liveBytes)
    let after = try importer.importConfig(at: target)
    #expect(
      LeaderKeySerializer.jsonValue(from: after) == LeaderKeySerializer.jsonValue(from: model))
    // And the live config itself was not touched.
    #expect(try Data(contentsOf: live) == liveBytes)
  }

  @Test func mismatchPathsPinpointDivergence() {
    let a = JSONValue.object([
      "key": .string("a"),
      "actions": .array([.object(["key": .string("x")])]),
    ])
    let b = JSONValue.object([
      "key": .string("b"),
      "actions": .array([.object(["key": .string("x"), "label": .string("hi")])]),
    ])
    let paths = JSONValue.mismatchPaths(a, b)
    #expect(paths.contains("$.key"))
    #expect(paths.contains("$.actions[0].label"))
  }
}
