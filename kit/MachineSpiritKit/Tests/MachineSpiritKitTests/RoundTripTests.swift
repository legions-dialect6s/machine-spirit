import Foundation
import Testing

@testable import MachineSpiritKit

/// THE MECHANICAL WITNESS — the round-trip gate. Green at every checkpoint
/// from [P1.3] forward. The tree view is the human witness; this is the
/// machine's.
struct RoundTripTests {
  /// A probe that never touches the machine the tests run on.
  struct FakeProbe: AvailabilityProbe {
    var everythingPresent: Bool
    func pathExists(_ path: String) -> Bool { everythingPresent }
    func rectanglePresent() -> Bool { everythingPresent }
    func tmuxPresent() -> Bool { everythingPresent }
  }

  func fixtureData(_ name: String) throws -> Data {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }

  @Test func importSerializeRoundTripIsCanonicallyEqual() throws {
    let data = try fixtureData("config")
    let importer = LeaderKeyImporter(probe: FakeProbe(everythingPresent: true))
    let root = try importer.importConfig(from: data)

    let serialized = LeaderKeySerializer.jsonValue(from: root)
    let expected = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(serialized == expected)
  }

  @Test func serializedBytesReparseToTheSameTree() throws {
    let data = try fixtureData("config")
    let importer = LeaderKeyImporter(probe: FakeProbe(everythingPresent: true))
    let root = try importer.importConfig(from: data)

    let bytes = try LeaderKeySerializer.data(from: root)
    let reparsed = try JSONDecoder().decode(JSONValue.self, from: bytes)
    let expected = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(reparsed == expected)
  }

  @Test func unknownFutureFieldsSurviveTheRoundTrip() throws {
    // Inject fake future fields at the root and inside a nested node, plus
    // an `iconPath` (known to Leader Key, deliberately not lifted by this
    // model — it must flow through extras).
    let data = try fixtureData("config")
    var json = try JSONDecoder().decode(JSONValue.self, from: data)

    guard var rootObject = json.objectValue,
      var actions = rootObject["actions"]?.arrayValue,
      var firstChild = actions.first?.objectValue
    else {
      Issue.record("fixture shape unexpected")
      return
    }
    rootObject["sigilGlow"] = .string("phosphor")
    firstChild["iconPath"] = .string("x")
    firstChild["futureNodeSetting"] = .object(["nested": .bool(true)])
    actions[0] = .object(firstChild)
    rootObject["actions"] = .array(actions)
    json = .object(rootObject)

    let mutated = try JSONEncoder().encode(json)
    let importer = LeaderKeyImporter(probe: FakeProbe(everythingPresent: true))
    let root = try importer.importConfig(from: mutated)

    #expect(root.extras["sigilGlow"] == .string("phosphor"))
    #expect(root.children[0].extras["iconPath"] == .string("x"))

    let serialized = LeaderKeySerializer.jsonValue(from: root)
    #expect(serialized == json)
  }

  @Test(arguments: ["{}", #"{"type":"group","actions":[]}"#, #"{"actions":[]}"#])
  func emptyConfigsImportAsEmptyGraphsAndRoundTrip(source: String) throws {
    let data = Data(source.utf8)
    let importer = LeaderKeyImporter(probe: FakeProbe(everythingPresent: false))
    let root = try importer.importConfig(from: data)
    #expect(root.children.isEmpty)
    #expect(root.action == nil)

    let serialized = LeaderKeySerializer.jsonValue(from: root)
    let expected = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(serialized == expected)
  }

  @Test func absentDependenciesImportWithoutCrashingAndDeriveInert() throws {
    let data = try fixtureData("config")
    let importer = LeaderKeyImporter(probe: FakeProbe(everythingPresent: false))
    let root = try importer.importConfig(from: data)

    var inertCount = 0
    var activeGroupCount = 0
    walk(root) { node in
      if node.status.isInert { inertCount += 1 }
      if node.action == nil, !node.status.isInert { activeGroupCount += 1 }
    }
    // Everything with a real dependency goes inert under an all-absent probe.
    #expect(inertCount > 0)
    // Groups carry no dependency and stay active.
    #expect(activeGroupCount > 0)

    // Inertness is derived, never stored: serialization is unaffected.
    let serialized = LeaderKeySerializer.jsonValue(from: root)
    let expected = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(serialized == expected)
  }

  @Test func statusRecomputesPerImport() throws {
    let data = try fixtureData("config")
    let optimist = try LeaderKeyImporter(probe: FakeProbe(everythingPresent: true))
      .importConfig(from: data)
    let pessimist = try LeaderKeyImporter(probe: FakeProbe(everythingPresent: false))
      .importConfig(from: data)

    var optimistInert = 0
    var pessimistInert = 0
    walk(optimist) { if $0.status.isInert { optimistInert += 1 } }
    walk(pessimist) { if $0.status.isInert { pessimistInert += 1 } }

    // The all-present probe leaves only __HOME__-templated values inert
    // (a templated fixture references no real path — honestly inert).
    #expect(optimistInert < pessimistInert)
  }

  @Test func nonObjectRootThrowsInsteadOfCrashing() {
    let importer = LeaderKeyImporter(probe: FakeProbe(everythingPresent: false))
    #expect(throws: ImportError.rootIsNotAnObject) {
      _ = try importer.importConfig(from: Data("[1,2,3]".utf8))
    }
  }

  func walk(_ node: Node, _ visit: (Node) -> Void) {
    visit(node)
    for child in node.children { walk(child, visit) }
  }
}
