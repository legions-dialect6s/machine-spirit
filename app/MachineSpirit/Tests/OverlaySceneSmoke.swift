import AppKit
import MachineSpiritKit

// swiftc -swift-version 6 -parse-as-library -I DerivedData/Build/Products/Debug \
// Sources/OverlayScene.swift Sources/NodePresentation.swift Tests/OverlaySceneSmoke.swift \
// DerivedData/Build/Products/Debug/MachineSpiritKit.o -o DerivedData/overlay-scene-smoke
@main struct OverlaySceneSmoke {
  static func main() throws {
    let root = try LeaderKeyImporter().importConfig(at: LeaderKeyImporter.liveConfigURL)
    var groups: [(Node, [Node])] = []
    var widths: [String: CGFloat] = [:]
    func visit(_ n: Node, _ ancestors: [Node]) {
      widths[n.id] = max(48, ceil((n.overlayLabel as NSString).size(withAttributes:
        [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)]).width) + 16)
      if !n.children.isEmpty { groups.append((n, ancestors)) }
      for child in n.children { visit(child, ancestors + [n]) }
    }
    visit(root, [])
    for id in ["root/1", "root/s/i", "root/s/s", "root/s/l", "root/t/q"] {
      if let node = root.node(withID: id) { print("\(id): \(node.displayName) → \(node.overlayLabel)") }
    }
    var cases = 0
    var worst = 0.0
    for size in [CGSize(width: 1728, height: 1117), CGSize(width: 1440, height: 900), CGSize(width: 2560, height: 1440)] {
      for fraction in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.01),
                       CGPoint(x: 0.015, y: 0.02), CGPoint(x: 0.985, y: 0.98)] {
        let anchor = CGPoint(x: fraction.x * size.width, y: fraction.y * size.height)
        for (focus, ancestors) in groups {
          let start = CACurrentMediaTime()
          let items = OverlayScene.layout(focus: focus, ancestors: ancestors, anchor: anchor, size: size, labelWidths: widths)
          worst = max(worst, (CACurrentMediaTime() - start) * 1000)
          precondition(items[focus.id]?.center == anchor)
          precondition(items.count == 1 + ancestors.count + focus.children.count + focus.children.reduce(0) { $0 + $1.children.count })
          let radius = OverlayScene.backdropRadius(items: items, focus: anchor, labelWidths: widths)
          precondition(items.values.allSatisfy {
            hypot($0.center.x - anchor.x, $0.center.y - anchor.y) + 24 * $0.scale < radius
          }, "Backdrop misses visible disc")
          var boxes: [CGRect] = []
          for child in focus.children {
            let item = items[child.id]!
            let width = widths[child.id]!
            let box = CGRect(x: item.center.x - width / 2, y: item.center.y - 24, width: width, height: 76)
            precondition(CGRect(origin: .zero, size: size).contains(box), "Child off screen: \(child.id)")
            precondition(!boxes.contains { $0.intersects(box) }, "Children overlap: \(focus.id), \(size), \(fraction)")
            boxes.append(box)
            for grandchild in child.children {
              let preview = items[grandchild.id]!
              precondition(preview.scale == 0.55 && preview.opacity == 0.45)
              precondition(CGRect(origin: .zero, size: size).contains(preview.center))
              precondition(preview.parent == child.id)
            }
          }
          cases += 1
        }
      }
    }
    print("PASS \(cases) live-config layouts: fixed anchor, full children + grandchildren + ancestors, child bounds/collisions. Worst \(worst)ms")
  }
}
