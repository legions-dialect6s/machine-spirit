import Foundation
import Testing
@testable import ms

@Test func coordinateReflectionUsesPrimaryScreenNotDesktopUnion() {
    let primaryTop: CGFloat = 1117
    let frames = [
        CGRect(x: 0, y: 40, width: 1728, height: 1053),
        CGRect(x: -2560, y: -323, width: 2560, height: 1440),
        CGRect(x: 0, y: 1117, width: 1920, height: 1080),
        CGRect(x: 1728, y: -1080, width: 1920, height: 1080),
    ]
    #expect(flipScreenRect(frames[0], primaryTop: primaryTop) == CGRect(x: 0, y: 24, width: 1728, height: 1053))
    #expect(flipScreenRect(frames[2], primaryTop: primaryTop).minY == -1080)
    #expect(flipScreenRect(frames[3], primaryTop: primaryTop).minY == 1117)
    for frame in frames {
        #expect(flipScreenRect(flipScreenRect(frame, primaryTop: primaryTop), primaryTop: primaryTop) == frame)
    }
}

@Test func allMouseZonesAndStrictBoundaries() {
    let screen = CGRect(x: -2000, y: 100, width: 1000, height: 800)
    let cases: [(CGFloat, CGFloat, Placement)] = [
        (0.05, 0.05, .tl), (0.95, 0.05, .tr), (0.05, 0.95, .bl), (0.95, 0.95, .br),
        (0.05, 0.5, .left), (0.95, 0.5, .right), (0.5, 0.05, .top), (0.5, 0.95, .bottom),
        (0.5, 0.5, .amm), (0.10, 0.5, .amm), (0.90, 0.5, .amm),
        (0.5, 0.10, .amm), (0.5, 0.90, .amm), (-0.1, -0.1, .tl), (1.1, 1.1, .br),
    ]
    for (u, v, mode) in cases {
        let point = CGPoint(x: screen.minX + u * screen.width, y: screen.maxY - v * screen.height)
        #expect(mouseZone(point, visibleFrame: screen) == mode)
    }
}

@Test func namedFramesRespectUsableArea() {
    let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1000)
    let huge = CGRect(x: 0, y: 0, width: 3000, height: 2000)
    #expect(placementFrame(.max, visibleFrame: screen, current: huge) == screen)
    #expect(placementFrame(.center, visibleFrame: screen, current: huge) == screen)
    #expect(placementFrame(.amm, visibleFrame: screen, current: huge) == CGRect(x: -1824, y: -150, width: 1728, height: 900))
    #expect(placementFrame(.br, visibleFrame: screen, current: huge) == CGRect(x: -960, y: 300, width: 960, height: 500))
    let small = CGRect(x: 20, y: 20, width: 400, height: 300)
    #expect(placementFrame(.center, visibleFrame: screen, current: small) == CGRect(x: -1160, y: 150, width: 400, height: 300))
}

@Test func ladderClassificationUsesEveryEdgeAndPerDimensionTolerance() {
    let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1000)
    for mode: Placement in [.tl, .tr, .bl, .br, .left, .right, .top, .bottom, .amm, .max] {
        let frame = placementFrame(mode, visibleFrame: screen, current: .zero)
        #expect(classifyPlacement(frame, visibleFrame: screen) == mode)
        #expect(classifyPlacement(frame.offsetBy(dx: 38, dy: 20), visibleFrame: screen) == mode)
        #expect(classifyPlacement(frame.offsetBy(dx: 39, dy: 0), visibleFrame: screen) == nil)
        #expect(classifyPlacement(frame.offsetBy(dx: 0, dy: 21), visibleFrame: screen) == nil)
        let oversized = CGRect(x: frame.minX, y: frame.minY, width: frame.width + 39, height: frame.height)
        #expect(classifyPlacement(oversized, visibleFrame: screen) == nil)
    }
    let small = CGRect(x: 0, y: 0, width: 500, height: 400)
    let quarter = placementFrame(.tl, visibleFrame: small, current: .zero)
    #expect(classifyPlacement(quarter.offsetBy(dx: 12, dy: 12), visibleFrame: small) == .tl)
    #expect(classifyPlacement(quarter.offsetBy(dx: 13, dy: 0), visibleFrame: small) == nil)
    #expect(classifyPlacement(CGRect(x: 7, y: 19, width: 333, height: 222), visibleFrame: screen) == nil)
}

@Test func growLadderAndFullscreenBounce() {
    let cases: [(Placement?, Placement)] = [(.tl, .left), (.bl, .left), (.tr, .right), (.br, .right),
        (.left, .amm), (.right, .amm), (.top, .amm), (.bottom, .amm), (.amm, .max), (.max, .fullscreen), (nil, .amm)]
    for (current, next) in cases {
        #expect(nextPlacement(current, fullscreen: false, fromFullscreen: false) == next)
    }
    #expect(nextPlacement(.max, fullscreen: false, fromFullscreen: true) == .amm)
    #expect(nextPlacement(nil, fullscreen: true, fromFullscreen: false) == .max)
    #expect(nextPlacement(.amm, fullscreen: false, fromFullscreen: true) == .max)
}

@Test func placementStateExpiryAndWindowIsolation() throws {
    let state = PlacementState(windowKey: "42:123", last: "max", fromFullscreen: true, t: 1000)
    #expect(state.matches("42:123", now: 1600))
    #expect(!state.matches("42:123", now: 1600.01))
    #expect(!state.matches("42:456", now: 1001))
    #expect(!state.matches("42:123", now: 999))
    let decoded = try JSONDecoder().decode(PlacementState.self, from: JSONEncoder().encode(state))
    #expect(decoded.fromFullscreen && decoded.last == "max")
}

@Test func currentScreenUsesLargestIntersection() {
    let screens = [CGRect(x: -1000, y: 0, width: 1000, height: 800), CGRect(x: 0, y: 0, width: 2000, height: 1000)]
    #expect(overlapScreen(CGRect(x: -100, y: 20, width: 800, height: 500), screens: screens) == 1)
    #expect(overlapScreen(CGRect(x: -900, y: 20, width: 1000, height: 500), screens: screens) == 0)
    #expect(overlapScreen(CGRect(x: 5000, y: 5000, width: 500, height: 500), screens: screens, fallback: 1) == 1)
}

@Test func tileRebalancesSmallestWindowsAndPreservesOthers() {
    let screens = [CGRect(x: 0, y: 0, width: 1000, height: 1000), CGRect(x: 1000, y: 0, width: 2000, height: 1000)]
    #expect(screenQuotas(count: 6, screens: screens) == [2, 4])
    let frames = (0..<6).map { CGRect(x: 10, y: 10, width: 100 + $0 * 10, height: 100) }
    #expect(tileAssignments(frames: frames, screens: screens, visibleFrames: screens) == [1, 1, 1, 1, 0, 0])
    #expect(screenQuotas(count: 1, screens: screens) == [0, 1])
    #expect(tileAssignments(frames: [], screens: screens, visibleFrames: screens).isEmpty)
    for count in 0...30 { #expect(screenQuotas(count: count, screens: screens).reduce(0, +) == count) }
}

@Test func gridGapsLastRowAndBounds() {
    let screen = CGRect(x: -1000, y: -500, width: 1000, height: 800)
    let frames = tileFrames(count: 5, visibleFrame: screen)
    #expect(frames.count == 5)
    #expect(frames[1].minX - frames[0].maxX == 6)
    #expect(frames[3].minY - frames[0].maxY == 6)
    #expect(frames[3].width == 497)
    #expect(frames[4].maxX == screen.maxX)
    #expect(frames[4].maxY == screen.maxY)
    #expect(tileFrames(count: 1, visibleFrame: screen) == [screen])
    #expect(tileFrames(count: 0, visibleFrame: screen).isEmpty)
    for count in 1...30 {
        let cells = tileFrames(count: count, visibleFrame: screen)
        for (i, cell) in cells.enumerated() {
            #expect(screen.insetBy(dx: -0.001, dy: -0.001).contains(cell))
            for other in cells.dropFirst(i + 1) { #expect(!cell.intersects(other)) }
        }
    }
}

@Test func windowMCPArgumentsAndSchema() throws {
    let specs = toolSpecs(allowClipboard: false)
    let placement = try #require(specs.first { $0.name == "win_place" })
    #expect(!placement.readOnly)
    #expect(throws: Failure.self) { try placement.validate([:]) }
    #expect(throws: Failure.self) { try placement.validate(["mode": "invalid"]) }
    try placement.validate(["mode": "smart", "app": "Safari"])
    #expect(try toolArguments("win_place", ["mode": "center", "app": "Safari"]) == ["place", "--app", "Safari", "--", "center"])
    #expect(try toolArguments("win_cycle", ["app": "Unreal Editor"]) == ["cycle", "--app", "Unreal Editor"])
    #expect(try toolArguments("win_tile_all", [:]) == ["tile-all"])
    #expect(specs.contains { $0.name == "mouse" && $0.readOnly })
}
