import Foundation
import Testing

@testable import MachineSpiritKit

struct LayoutTests {
  struct FakeProbe: AvailabilityProbe {
    func pathExists(_ path: String) -> Bool { true }
    func rectanglePresent() -> Bool { true }
    func tmuxPresent() -> Bool { true }
  }

  func fixtureRoot() throws -> Node {
    let url = try #require(
      Bundle.module.url(forResource: "config", withExtension: "json", subdirectory: "Fixtures"))
    return try LeaderKeyImporter(probe: FakeProbe())
      .importConfig(from: try Data(contentsOf: url))
  }

  @Test func layoutIsDeterministic() throws {
    let root = try fixtureRoot()
    let first = TidyTreeLayout.layout(root: root)
    let second = TidyTreeLayout.layout(root: root)
    #expect(first == second)
  }

  @Test func everyNodeGetsAPosition() throws {
    let root = try fixtureRoot()
    let layout = TidyTreeLayout.layout(root: root)
    #expect(layout.positions.count == root.totalCount)

    var missing: [String] = []
    func walk(_ node: Node) {
      if layout.positions[node.id] == nil { missing.append(node.id) }
      for child in node.children { walk(child) }
    }
    walk(root)
    #expect(missing.isEmpty)
  }

  @Test func depthGrowsRightwardAndSiblingsDoNotCollide() throws {
    let root = try fixtureRoot()
    let layout = TidyTreeLayout.layout(root: root)

    func walk(_ node: Node) {
      let parent = layout.positions[node.id]!
      for child in node.children {
        #expect(layout.positions[child.id]!.x > parent.x)
      }
      // Siblings occupy distinct vertical bands.
      let ys = node.children.map { layout.positions[$0.id]!.y }
      #expect(Set(ys).count == ys.count)
      for child in node.children { walk(child) }
    }
    walk(root)
  }

  @Test func singleChildChainsCompress() throws {
    let root = try fixtureRoot()
    let layout = TidyTreeLayout.layout(
      root: root, rowHeight: 34, columnStep: 190, chainStep: 74)

    // ⇪ q u i t: u → i → t is a single-child run and must take the short
    // step; root → its many children takes the full step.
    let u = try #require(layout.positions["root/q/u"])
    let i = try #require(layout.positions["root/q/u/i"])
    let t = try #require(layout.positions["root/q/u/i/t"])
    #expect(i.x - u.x == 74)
    #expect(t.x - i.x == 74)

    let rootPos = try #require(layout.positions["root"])
    let q = try #require(layout.positions["root/q"])
    #expect(q.x - rootPos.x == 190)
  }

  @Test func parentsCenterOnTheirChildren() throws {
    let root = try fixtureRoot()
    let layout = TidyTreeLayout.layout(root: root)

    for child in root.children where child.children.count >= 2 {
      let ys = child.children.map { layout.positions[$0.id]!.y }
      let mid = (ys.min()! + ys.max()!) / 2
      // Tidy-tree centering: parent sits at the midpoint of its first and
      // last child (which for sorted bands equals min/max midpoint).
      #expect(abs(layout.positions[child.id]!.y - mid) < 0.0001)
    }
  }
}
