import Foundation
import MachineSpiritKit

/// Geometry only. The overlay owns persistent CA layers; no drawing clock or
/// SwiftUI objects live here. Coordinates are local, with y increasing down.
struct OverlayScene {
  static func backdropRadius(items: [String: Item], focus: CGPoint,
                             labelWidths: [String: CGFloat]) -> CGFloat {
    items.reduce(CGFloat(52)) { radius, entry in
      let item = entry.value
      let reach = item.label
        ? hypot((labelWidths[entry.key] ?? 48) / 2, 50) * item.scale
        : 24 * item.scale
      return max(radius, hypot(item.center.x - focus.x, item.center.y - focus.y) + reach + 32)
    }
  }

  struct Item {
    var center: CGPoint
    var scale: CGFloat
    var opacity: Float
    var label: Bool
    var parent: String?
    var delay: Double = 0
  }

  static func layout(focus: Node, ancestors: [Node], anchor: CGPoint,
                     size: CGSize, labelWidths: [String: CGFloat], safeRect: CGRect? = nil) -> [String: Item] {
    struct Box {
      let x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat
      init(_ r: CGRect) { x0 = r.origin.x; y0 = r.origin.y; x1 = r.origin.x + r.size.width; y1 = r.origin.y + r.size.height }
    }
    let safe = (safeRect ?? CGRect(origin: .zero, size: size)).insetBy(dx: 5, dy: 5)
    // Only the actual root may occupy menu/Dock space. A focused letter must
    // remain inside the safe frame, even when the session began in the bar.
    let rootAnchor = anchor
    let anchor = ancestors.isEmpty ? anchor : CGPoint(
      x: min(max(anchor.x, safe.minX + 24), safe.maxX - 24),
      y: min(max(anchor.y, safe.minY + 24), safe.maxY - 24))
    let dx = (size.width / 2 - anchor.x) / max(1, size.width / 2)
    let dy = (size.height / 2 - anchor.y) / max(1, size.height / 2)
    let radial = abs(dx) <= 0.35 && abs(dy) <= 0.35
    let corner = abs(dx) > 0.65 && abs(dy) > 0.65
    let direction = atan2(dy * size.height, dx * size.width)
    let span = radial ? 2 * Double.pi : (corner ? 110 : 180) * Double.pi / 180
    var result = [focus.id: Item(center: anchor, scale: 1, opacity: 1,
                                 label: false, parent: nil)]
    // Spatial buckets avoid scanning the entire fan for every candidate.
    // The dense root has 100 visible nodes; local collision queries matter.
    let cell: CGFloat = 80
    let columns = max(1, Int(ceil(size.width / cell)))
    let rows = max(1, Int(ceil(size.height / cell)))
    var buckets = Array(repeating: [Box](), count: columns * rows)
    func cells(_ rect: Box) -> (Int, Int, Int, Int) {
      (max(0, min(columns - 1, Int(rect.x0 / cell))),
       max(0, min(columns - 1, Int(rect.x1 / cell))),
       max(0, min(rows - 1, Int(rect.y0 / cell))),
       max(0, min(rows - 1, Int(rect.y1 / cell))))
    }
    func reserve(_ rect: CGRect) {
      let b = Box(rect)
      let (x0, x1, y0, y1) = cells(b)
      for y in y0...y1 { for x in x0...x1 { buckets[y * columns + x].append(b) } }
    }
    if !ancestors.isEmpty {
      reserve(CGRect(x: rootAnchor.x - 30, y: rootAnchor.y - 30, width: 60, height: 60))
    }
    let focusRadius: CGFloat = ancestors.isEmpty ? 30 : 26
    reserve(CGRect(x: anchor.x - focusRadius, y: anchor.y - focusRadius, width: focusRadius * 2, height: focusRadius * 2))
    func box(_ point: CGPoint, width: CGFloat, small: Bool) -> CGRect {
      CGRect(x: point.x - width / 2, y: point.y - (small ? 16 : 24),
             width: width, height: small ? 34 : 76)
    }
    func fits(_ rect: CGRect) -> Bool {
      let b = Box(rect)
      guard b.x0 >= safe.minX, b.y0 >= safe.minY, b.x1 <= safe.maxX, b.y1 <= safe.maxY else { return false }
      let (x0, x1, y0, y1) = cells(b)
      for y in y0...y1 {
        for x in x0...x1 {
          for other in buckets[y * columns + x] {
            if b.x0 < other.x1 && b.x1 > other.x0 && b.y0 < other.y1 && b.y1 > other.y0 { return false }
          }
        }
      }
      return true
    }
    // First-fit search, bounded by the display. Unlike the old exhaustive
    // best-score search this stays cheap even for the 28-key root fan.
    func place(origin: CGPoint, angle: Double, radius: Double, width: CGFloat,
               small: Bool, sector: Double, heading: Double) -> CGPoint {
      let step = small ? 32.0 : 76.0
      var directions: [(Double, Double)] = []
      directions.reserveCapacity(17)
      for offset in 0..<17 {
        let a = angle + Double((offset + 1) / 2) * 0.18 * (offset % 2 == 0 ? 1 : -1)
        let delta = abs(a - heading)
        guard min(delta, abs(delta - 2 * .pi)) <= sector / 2 + 0.001 else { continue }
        directions.append((cos(a), sin(a)))
      }
      for ring in 0..<16 {
        let r = radius + Double((ring + 1) / 2) * step * (ring % 2 == 0 ? 1 : -1)
        guard r >= (small ? 45 : 72) else { continue }
        for (vx, vy) in directions {
          let point = CGPoint(x: origin.x + vx * r, y: origin.y + vy * r)
          if fits(box(point, width: width, small: small)) { return point }
        }
      }
      // Exhausted sectors near corners may use remaining screen space.
      // Keep every node visible; very small displays can still run out.
      let strideSize: CGFloat = small ? 38 : 78
      var best: CGPoint?
      var bestScore = CGFloat.infinity
      for y in stride(from: safe.minY + 25, through: safe.maxY - 52, by: strideSize) {
        for x in stride(from: safe.minX + width / 2, through: safe.maxX - width / 2, by: strideSize) {
          let deltaX = x - origin.x, deltaY = y - origin.y
          let score = deltaX * deltaX + deltaY * deltaY
          guard score < bestScore else { continue }
          let p = CGPoint(x: x, y: y)
          if fits(box(p, width: width, small: small)) { best = p; bestScore = score }
        }
      }
      if let best { return best }
      return CGPoint(x: min(max(origin.x, safe.minX + width / 2), safe.maxX - width / 2),
                     y: min(max(origin.y, safe.minY + 24), safe.maxY - 52))
    }
    let count = focus.children.count
    let radius = max(135, min(radial ? 330 : 480, Double(count) * 85 / span))
    // Reserve ALL full-size children before allocating the preview branches.
    for (i, child) in focus.children.enumerated() {
      let fraction = radial ? Double(i) / Double(max(1, count)) : Double(i + 1) / Double(count + 1)
      let angle = radial ? -.pi / 2 + fraction * span : direction - span / 2 + fraction * span
      let width = max(54, labelWidths[child.id] ?? 110) + 8
      let center = place(origin: anchor, angle: angle, radius: radius, width: width,
                         small: false, sector: span, heading: radial ? angle : direction)
      reserve(box(center, width: width, small: false))
      result[child.id] = Item(center: center, scale: 1, opacity: 1, label: true,
                             parent: focus.id, delay: min(0.04, Double(i) * 0.008))
    }
    for child in focus.children {
      guard let parent = result[child.id] else { continue }
      let outward = atan2(parent.center.y - anchor.y, parent.center.x - anchor.x)
      for (i, grandchild) in child.children.enumerated() {
        let arc = min(Double.pi * 0.9, Double(child.children.count) * 0.48)
        let angle = outward - arc / 2 + arc * Double(i + 1) / Double(child.children.count + 1)
        let center = place(origin: parent.center, angle: angle, radius: 80,
                           width: 38, small: true, sector: .pi, heading: outward)
        reserve(box(center, width: 38, small: true))
        result[grandchild.id] = Item(center: center, scale: 0.55, opacity: 0.45,
                                    label: false, parent: child.id, delay: parent.delay)
      }
    }
    // Ancestors sit behind the focus, dim. At an edge, bend the breadcrumb
    // chain into available space instead of letting it disappear offscreen.
    var previous = focus.id
    for (i, ancestor) in ancestors.reversed().enumerated() {
      let center = ancestor.id == ancestors.first?.id && !safe.contains(rootAnchor) ? rootAnchor : place(origin: anchor, angle: direction + .pi, radius: Double(i + 1) * 65,
                         width: 38, small: true, sector: 2 * .pi, heading: 0)
      reserve(box(center, width: 38, small: true))
      result[ancestor.id] = Item(center: center, scale: 0.65, opacity: 0.25,
                                label: false, parent: nil)
      result[previous]?.parent = ancestor.id
      previous = ancestor.id
    }
    // Optional grandchild labels are granted only after all discs are placed.
    for child in focus.children {
      for node in child.children {
        guard var item = result[node.id] else { continue }
        let width = (labelWidths[node.id] ?? 110) * 0.55
        let label = CGRect(x: item.center.x - width / 2, y: item.center.y + 17,
                           width: width, height: 13)
        if fits(label) { item.label = true; reserve(label); result[node.id] = item }
      }
    }
    return result
  }
}
