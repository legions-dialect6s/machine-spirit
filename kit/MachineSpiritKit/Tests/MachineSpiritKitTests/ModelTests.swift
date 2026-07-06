import Foundation
import Testing

@testable import MachineSpiritKit

struct ModelTests {
  struct FakeProbe: AvailabilityProbe {
    var everythingPresent: Bool
    func pathExists(_ path: String) -> Bool { everythingPresent }
    func rectanglePresent() -> Bool { everythingPresent }
    func tmuxPresent() -> Bool { everythingPresent }
  }

  func fixtureRoot(present: Bool = true) throws -> Node {
    let url = try #require(
      Bundle.module.url(forResource: "config", withExtension: "json", subdirectory: "Fixtures"))
    return try LeaderKeyImporter(probe: FakeProbe(everythingPresent: present))
      .importConfig(from: try Data(contentsOf: url))
  }

  @Test func windowActionDerivesFromRectangleCommands() {
    let payload = ActionPayload.command(
      #"open -g "rectangle://execute-action?name=top-left""#)
    #expect(payload.windowAction == "top-left")
    // Derivation never alters the stored value string.
    #expect(payload.value == #"open -g "rectangle://execute-action?name=top-left""#)

    #expect(ActionPayload.command("echo hello").windowAction == nil)
    #expect(ActionPayload.application(path: "/Applications/X.app").windowAction == nil)
  }

  @Test func fixtureCarriesTheWindowActionFleet() throws {
    // The live config holds ~17 rectangle:// binds (halves, thirds, corners,
    // maximize, next-display); the fixture tracks it closely. Assert the
    // fleet imports as derived window actions without pinning an exact count.
    let root = try fixtureRoot()
    var names: [String] = []
    walk(root) { node in
      if let name = node.action?.windowAction { names.append(name) }
    }
    #expect(names.count >= 15)
    #expect(names.contains("maximize"))
    #expect(names.contains("next-display"))
    #expect(names.contains("top-left"))
  }

  @Test func nodeHoldsGroupAndActionDualityNatively() throws {
    // The headline capability: one node that is BOTH group and action —
    // ring and core. LK's own configs never produce it; the model holds it.
    let dual = Node(
      id: "root/s",
      key: "s",
      action: .command("~/bin/tmux-sheol-open.sh"),
      children: [
        Node(id: "root/s/r", key: "r", action: .command("revive"))
      ],
      hadChildrenArray: true
    )
    #expect(dual.isDual)

    // It serializes with BOTH value and actions present.
    let object = LeaderKeySerializer.jsonValue(from: dual).objectValue
    #expect(object?["value"] != nil)
    #expect(object?["actions"] != nil)

    // And reimports without losing either half.
    let bytes = try LeaderKeySerializer.data(from: dual)
    let reimported = try LeaderKeyImporter(probe: FakeProbe(everythingPresent: true))
      .importConfig(from: bytes)
    #expect(reimported.action != nil)
    #expect(reimported.children.count == 1)
  }

  @Test func structuralIDsFollowKeyPaths() throws {
    let root = try fixtureRoot()
    // ⇪ g p → ChatGPT.app in the fixture.
    let node = try #require(root.node(withID: "root/g/p"))
    #expect(node.action == .application(path: "/Applications/ChatGPT.app"))
  }

  @Test func valuesStayOpaque() throws {
    // __HOME__ templating and even trailing whitespace survive import
    // byte-for-byte; the model never expands or trims.
    let root = try fixtureRoot()
    let aesthetics = try #require(root.node(withID: "root/f/a/e"))
    #expect(aesthetics.action == .folder(path: "__HOME__/Desktop/aesthetics "))
  }

  @Test func unknownActionTypesImportAsOther() throws {
    let source = #"{"type":"group","actions":[{"key":"z","type":"hologram","value":"beam"}]}"#
    let root = try LeaderKeyImporter(probe: FakeProbe(everythingPresent: true))
      .importConfig(from: Data(source.utf8))
    #expect(root.children[0].action == .other(type: "hologram", value: "beam"))

    let serialized = LeaderKeySerializer.jsonValue(from: root)
    let expected = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
    #expect(serialized == expected)
  }

  @Test func graphViewStateRoundTrips() throws {
    let state = GraphViewState(
      zoom: 1.5,
      panX: -40,
      panY: 220,
      nodes: [
        "root/t/m/u/x": .init(x: 100, y: 60, collapsed: false),
        "root/q": .init(x: -30, y: 0, collapsed: true),
      ]
    )
    let decoded = try GraphViewState.load(from: try state.data())
    #expect(decoded == state)
  }

  func walk(_ node: Node, _ visit: (Node) -> Void) {
    visit(node)
    for child in node.children { walk(child, visit) }
  }
}
