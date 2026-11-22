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

@Test func directionalMovesUsePhysicalLayoutAndStopAtOuterEdges() {
    let origin = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let screens = [origin, origin.offsetBy(dx: 0, dy: 800), origin.offsetBy(dx: -1000, dy: -160),
                   origin.offsetBy(dx: 1000, dy: 250), origin.offsetBy(dx: -170, dy: -800)]
    for (mode, expected): (Placement, Int) in [(.displayLeft, 2), (.displayRight, 3), (.displayUp, 4), (.displayDown, 1)] {
        #expect(destinationDisplay(for: mode, from: 0, screens: screens) == expected)
        #expect(destinationDisplay(for: mode, from: expected, screens: screens) == nil)
        #expect(destinationDisplay(for: mode, from: 0, screens: [origin]) == nil)
    }
    #expect(destinationDisplay(for: .displayUp, from: 0, screens: []) == nil)
    #expect(destinationDisplay(for: .displayRight, from: 0, screens: [origin, origin]) == nil)
}

@Test func alignedDisplaysWinOverDiagonalsAndOffsetsBreakTies() {
    let origin = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let diagonal = origin.offsetBy(dx: 1000, dy: 900)
    let far = origin.offsetBy(dx: 2300, dy: 0)
    let offCenter = CGRect(x: 1100, y: -500, width: 1000, height: 800)
    let center = CGRect(x: 1100, y: 300, width: 1000, height: 800)
    #expect(destinationDisplay(for: .displayRight, from: 0, screens: [origin, diagonal]) == 1)
    #expect(destinationDisplay(for: .displayRight, from: 0, screens: [origin, diagonal, far]) == 2)
    #expect(destinationDisplay(for: .displayRight, from: 0, screens: [origin, offCenter, far, center]) == 3)
    // A display above the right half of the current one belongs to Up.
    let above = CGRect(x: 500, y: -800, width: 1000, height: 800)
    #expect(destinationDisplay(for: .displayRight, from: 0, screens: [origin, above]) == nil)
    #expect(destinationDisplay(for: .displayUp, from: 0, screens: [origin, above]) == 1)
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

@Test func transfersRespectOffsetScreens() {
    let source = CGRect(x: -1600, y: 50, width: 1600, height: 1000)
    let dest = CGRect(x: 0, y: -900, width: 1200, height: 800)
    let frame = CGRect(x: -1200, y: 300, width: 800, height: 500)
    #expect(transferredFrame(frame, from: source, to: dest) == CGRect(x: 300, y: -700, width: 600, height: 400))
}

@Test @MainActor func rectangleBridgeRejectsNonActionURLsBeforeDispatch() async {
    for url in ["https://example.com", "rectangle://execute-action?name=",
                "rectangle://execute-action?name=right-half&extra=true"] {
        await #expect(throws: Failure.self) { _ = try await runRectangleAction([url]) }
    }
}

@Test func centerChordsAlternateAndEdgeRepeatsStayWithTheirWindow() {
    let last = PlacementState(windowKey: "7:8", last: "tl", fromFullscreen: false, t: 20, aimZone: .tl, aimScreen: 4)
    func result(_ zone: Placement, _ current: Placement?, key: String = "7:8", screen: UInt32 = 4, now: Double = 21) -> Placement {
        aimedPlacement(zone: zone, current: current, fullscreen: false, previous: last, key: key, screen: screen, now: now)
    }
    #expect(result(.amm, nil) == .amm)
    #expect(result(.amm, .amm) == .max)
    #expect(result(.amm, .max) == .amm)
    #expect(result(.tl, .tl) == .left)
    #expect(result(.tl, .tl, key: "7:9") == .tl)
    #expect(result(.tl, .tl, screen: 8) == .tl)
    #expect(result(.tl, .tl, now: 24) == .tl)
    #expect(aimedPlacement(zone: .tl, current: nil, fullscreen: true, previous: last,
                          key: "7:8", screen: 4, now: 21, windowIsOnScreen: false) == .tl)
    #expect(aimedPlacement(zone: .tl, current: nil, fullscreen: true, previous: last,
                          key: "7:8", screen: 4, now: 21) == .max)
}

@Test func displayCyclesFollowPhysicalOrderAndWrap() {
    let laptop = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let left = CGRect(x: -2560, y: -974, width: 2560, height: 1440)
    let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
    let screens = [laptop, left, above]
    #expect(destinationDisplay(for: .displayNext, from: 0, screens: screens) == 2)
    #expect(destinationDisplay(for: .displayNext, from: 1, screens: screens) == 0)
    #expect(destinationDisplay(for: .displayNext, from: 2, screens: screens) == 1)
    #expect(destinationDisplay(for: .displayPrevious, from: 0, screens: screens) == 1)
    #expect(destinationDisplay(for: .displayPrevious, from: 1, screens: screens) == 2)
    #expect(destinationDisplay(for: .displayNext, from: 0, screens: [laptop]) == nil)
    #expect(destinationDisplay(for: .displayPrevious, from: 0, screens: [laptop]) == nil)
    #expect(destinationDisplay(for: .displayUp, from: 0, screens: screens) == 2)
    #expect(destinationDisplay(for: .displayDown, from: 2, screens: screens) == 0)
}

@Test func verticalHalfStepsEnterOppositeHalfAndRequireAnAlignedDisplay() throws {
    let source = CGRect(x: 0, y: 0, width: 1200, height: 900)
    let above = CGRect(x: 100, y: -750, width: 1000, height: 750)
    let below = CGRect(x: -400, y: 910, width: 1400, height: 850)
    let diagonal = CGRect(x: 1200, y: 900, width: 1200, height: 900)
    let screens = [source, above, below, diagonal]
    let available = screens.map { $0.insetBy(dx: 10, dy: 20) }
    let ddd = placementFrame(.right, visibleFrame: available[0], current: source)

    for (mode, localHalf, arrivalHalf, neighbor): (Placement, Placement, Placement, Int) in [
        (.halfDown, .bottom, .top, 2), (.halfUp, .top, .bottom, 1)
    ] {
        let first = try #require(verticalHalfStep(for: mode, window: ddd, from: 0, screens: screens, visible: available))
        #expect(first.screen == 0 && first.half == localHalf)
        #expect(first.frame == placementFrame(localHalf, visibleFrame: available[0], current: ddd))
        let crossing = try #require(verticalHalfStep(for: mode, window: first.frame.offsetBy(dx: 1, dy: -1), from: 0,
                                                       screens: screens, visible: available))
        #expect(crossing.screen == neighbor && crossing.half == arrivalHalf)
        #expect(crossing.frame == placementFrame(arrivalHalf, visibleFrame: available[neighbor], current: first.frame))
        let final = try #require(verticalHalfStep(for: mode, window: crossing.frame, from: neighbor, screens: screens, visible: available))
        #expect(final.screen == neighbor && final.half == localHalf)
        #expect(verticalHalfStep(for: mode, window: final.frame, from: neighbor, screens: screens, visible: available) == nil)
        #expect(verticalHalfStep(for: mode, window: first.frame, from: 0, screens: [source, diagonal],
                                 visible: [available[0], available[3]]) == nil)
    }
}

@Test func constrainedHalfRequiresConfirmedWindowDisplayAndUnchangedBounds() throws {
    let upper = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
    let lower = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let visible = [upper.insetBy(dx: 0, dy: 15), lower.insetBy(dx: 0, dy: 33)]
    let constrained = CGRect(x: 0, y: -540, width: 1728, height: 597)
    let previous = PlacementState(windowKey: "42:123", last: "bottom", fromFullscreen: false, t: 100,
                                  halfLanding: .init(screen: 3, frame: constrained, usable: visible[0]))
    let restored = try JSONDecoder().decode(PlacementState.self, from: JSONEncoder().encode(previous))
    let reference = restored.confirmedHalf(key: "42:123", screen: 3, frame: constrained, usable: visible[0], now: 101)
    #expect(reference == .bottom)
    #expect(restored.confirmedHalf(key: "42:124", screen: 3, frame: constrained, usable: visible[0], now: 101) == nil)
    #expect(restored.confirmedHalf(key: "42:123", screen: 2, frame: constrained, usable: visible[0], now: 101) == nil)
    #expect(restored.confirmedHalf(key: "42:123", screen: 3, frame: constrained.offsetBy(dx: 4, dy: 0), usable: visible[0], now: 101) == nil)
    #expect(restored.confirmedHalf(key: "42:123", screen: 3, frame: constrained, usable: upper, now: 101) == nil)
    #expect(restored.confirmedHalf(key: "42:123", screen: 3, frame: constrained, usable: visible[0], now: 701) == nil)

    let initial = try #require(verticalHalfStep(for: .halfDown, window: constrained, from: 0,
                                                screens: [upper, lower], visible: visible))
    #expect(initial.screen == 0 && initial.half == .bottom)
    let crossed = try #require(verticalHalfStep(for: .halfDown, window: constrained, from: 0,
                                                screens: [upper, lower], visible: visible, confirmedHalf: reference))
    #expect(crossed.screen == 1 && crossed.half == .top)
    #expect(verticalHalfStep(for: .halfDown, window: constrained, from: 0, screens: [upper],
                             visible: [visible[0]], confirmedHalf: reference) == nil)
}
