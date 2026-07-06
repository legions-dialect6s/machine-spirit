import Foundation
import Testing

@testable import MachineSpiritKit

struct RadialLayoutTests {
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

  @Test func deterministicAndComplete() throws {
    let root = try fixtureRoot()
    let first = RadialLayout.layout(root: root)
    let second = RadialLayout.layout(root: root)
    #expect(first == second)
    #expect(first.positions.count == root.totalCount)
  }

  @Test func rootSitsAtTheCenter() throws {
    let root = try fixtureRoot()
    let layout = RadialLayout.layout(root: root)
    let center = try #require(layout.positions["root"])
    #expect(abs(center.x) < 0.0001)
    #expect(abs(center.y) < 0.0001)
  }

  @Test func depthGrowsOutwardAndChainsCompress() throws {
    let root = try fixtureRoot()
    let layout = RadialLayout.layout(root: root, ringStep: 150, chainStep: 66)

    func radius(_ id: String) throws -> Double {
      let p = try #require(layout.positions[id])
      return (p.x * p.x + p.y * p.y).squareRoot()
    }

    // Children sit strictly farther out than their parents.
    func walk(_ node: Node) throws {
      let r = try radius(node.id)
      for child in node.children {
        #expect(try radius(child.id) > r)
        try walk(child)
      }
    }
    try walk(root)

    // q-u-i-t: the u → i → t run is single-child — short radial hops
    // (arc pressure can stretch a hop outward, never compress it).
    let u = try radius("root/q/u")
    let i = try radius("root/q/u/i")
    let t = try radius("root/q/u/i/t")
    #expect(i - u >= 66 - 0.0001)
    #expect(t - i >= 66 - 0.0001)
  }

  @Test func siblingsNeverCollideAnywhere() throws {
    let root = try fixtureRoot()
    let layout = RadialLayout.layout(root: root, minSpacing: 40)

    // Fixed-size nodes are ~26pt on screen at zoom 1: every sibling pair at
    // every depth keeps at least a node diameter of air.
    func walk(_ node: Node) {
      let points = node.children.compactMap { layout.positions[$0.id] }
      for a in 0..<points.count {
        for b in (a + 1)..<points.count {
          let dx = points[a].x - points[b].x
          let dy = points[a].y - points[b].y
          #expect((dx * dx + dy * dy).squareRoot() > 26)
        }
      }
      for child in node.children { walk(child) }
    }
    walk(root)
  }
}
