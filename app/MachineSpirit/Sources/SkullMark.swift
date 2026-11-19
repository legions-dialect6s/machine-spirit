import CoreGraphics

/// Reusable cyber-gothic mark, in a normalized 44pt square (y increases down).
/// Render with even-odd fill so eyes, nose and teeth cut through the silhouette.
enum SkullMark {
  static func path(in rect: CGRect = CGRect(x: 0, y: 0, width: 44, height: 44)) -> CGPath {
    let p = CGMutablePath()
    func polygon(_ points: [CGPoint]) {
      guard let first = points.first else { return }
      p.move(to: first); points.dropFirst().forEach { p.addLine(to: $0) }; p.closeSubpath()
    }
    polygon([CGPoint(x: 5,y: 10), CGPoint(x: 12,y: 2), CGPoint(x: 22,y: 0),
      CGPoint(x: 32,y: 2), CGPoint(x: 39,y: 10), CGPoint(x: 42,y: 24),
      CGPoint(x: 35,y: 31), CGPoint(x: 31,y: 31), CGPoint(x: 30,y: 40),
      CGPoint(x: 26,y: 44), CGPoint(x: 18,y: 44), CGPoint(x: 14,y: 40),
      CGPoint(x: 13,y: 31), CGPoint(x: 9,y: 31), CGPoint(x: 2,y: 24)])
    polygon([CGPoint(x: 8,y: 14), CGPoint(x: 20,y: 19), CGPoint(x: 17,y: 26), CGPoint(x: 9,y: 24)])
    polygon([CGPoint(x: 36,y: 14), CGPoint(x: 24,y: 19), CGPoint(x: 27,y: 26), CGPoint(x: 35,y: 24)])
    polygon([CGPoint(x: 22,y: 25), CGPoint(x: 18,y: 32), CGPoint(x: 26,y: 32)])
    for x in [18, 22, 26] { p.addRect(CGRect(x: x - 1, y: 36, width: 2, height: 8)) }
    var transform = CGAffineTransform(a: rect.width / 44, b: 0, c: 0,
      d: rect.height / 44, tx: rect.minX, ty: rect.minY)
    return p.copy(using: &transform)!
  }
}
