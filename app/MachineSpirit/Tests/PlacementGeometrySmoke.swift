import Foundation
@testable import MachineSpirit

/// Compile alongside the actual CLI WindowGeometry.swift, not a second test copy.
@main struct PlacementGeometrySmoke {
  static func main() {
    var cases = 0
    for screen in [CGRect(x: 0, y: 38, width: 1728, height: 1000),
                   CGRect(x: -1920, y: -580, width: 1920, height: 1080),
                   CGRect(x: 100, y: 1600, width: 1280, height: 720)] {
      let primaryTop: CGFloat = 1117
      for u in [-0.1, 0, 0.05, 0.0999, 0.1, 0.1001, 0.5, 0.8999, 0.9, 0.9001, 0.95, 1, 1.1] {
        for v in [-0.1, 0, 0.05, 0.0999, 0.1, 0.1001, 0.5, 0.8999, 0.9, 0.9001, 0.95, 1, 1.1] {
          let mouse = CGPoint(x: screen.minX + screen.width * u, y: screen.maxY - screen.height * v)
          let zone = mouseZone(mouse, visibleFrame: screen)
          let ax = placementFrame(zone, visibleFrame: flipScreenRect(screen, primaryTop: primaryTop), current: .zero)
          let expected = flipScreenRect(ax, primaryTop: primaryTop)
          let actual = SmartPlacement.target(mouse: mouse, visibleFrame: screen).frame
          precondition(abs(actual.minX - expected.minX) < 0.0001 && abs(actual.minY - expected.minY) < 0.0001
                       && actual.size == expected.size, "CLI parity failed at \(mouse)")
          cases += 1
        }
      }
    }
    print("PASS \(cases) placement cases against CLI math: all zones, threshold boundaries, negative and stacked screens")
  }
}
