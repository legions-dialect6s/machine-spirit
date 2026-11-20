import Foundation

/// AppKit <-> AX global rectangles. The same reflection works in both directions.
/// primaryTop is the PRIMARY screen's maxY, never the union of all screens.
func flipScreenRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
}

enum Placement: String, CaseIterable, Codable {
    case smart, step, amm, max, left, right, top, bottom, tl, tr, bl, br, center, fullscreen
    case displayLeft = "display-left", displayRight = "display-right"
    case displayUp = "display-up", displayDown = "display-down"

    var isDisplayTransfer: Bool {
        switch self {
        case .displayLeft, .displayRight, .displayUp, .displayDown: return true
        default: return false
        }
    }
}

/// Display frames use AX coordinates (up is negative y). Prefer a neighbor across
/// the requested edge, then the nearest diagonal if there is no aligned display.
func destinationDisplay(for mode: Placement, from index: Int, screens: [CGRect]) -> Int? {
    guard screens.indices.contains(index), screens.count > 1, mode.isDisplayTransfer else { return nil }

    let horizontal = mode == .displayLeft || mode == .displayRight
    let positive = mode == .displayRight || mode == .displayDown
    // Project onto the travel axis and the perpendicular axis for all four arrows.
    func axes(_ rect: CGRect) -> (along: ClosedRange<CGFloat>, across: ClosedRange<CGFloat>) {
        let x = rect.minX...rect.maxX, y = rect.minY...rect.maxY
        return horizontal ? (x, y) : (y, x)
    }
    let source = axes(screens[index])
    var best: (aligned: Int, distance: CGFloat, offset: CGFloat, index: Int)?
    for candidate in screens.indices where candidate != index {
        let next = axes(screens[candidate])
        let forward = positive ? next.along.lowerBound - source.along.upperBound
                               : source.along.lowerBound - next.along.upperBound
        guard forward >= 0 else { continue }
        let overlap = min(source.across.upperBound, next.across.upperBound)
                    - max(source.across.lowerBound, next.across.lowerBound)
        let offset = horizontal ? abs(screens[index].midY - screens[candidate].midY)
                                : abs(screens[index].midX - screens[candidate].midX)
        let distance: CGFloat = hypot(forward, max(0, -overlap))
        let rank = (overlap > 0 ? 0 : 1, distance, offset, candidate)
        if let best, best <= rank { continue }
        best = rank
    }
    return best?.index
}

/// Mouse and visibleFrame are AppKit coordinates; normalized v increases downward.
func mouseZone(_ point: CGPoint, visibleFrame: CGRect) -> Placement {
    guard visibleFrame.width > 0, visibleFrame.height > 0 else { return .amm }
    let u = min(1, max(0, (point.x - visibleFrame.minX) / visibleFrame.width))
    let v = min(1, max(0, (visibleFrame.maxY - point.y) / visibleFrame.height))
    let left = u < 0.10, right = u > 0.90, top = v < 0.10, bottom = v > 0.90
    if top && left { return .tl }; if top && right { return .tr }
    if bottom && left { return .bl }; if bottom && right { return .br }
    if left { return .left }; if right { return .right }
    if top { return .top }; if bottom { return .bottom }
    return .amm
}

/// Preserve the relative position and size within the usable area of each display.
func transferredFrame(_ frame: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
    guard source.width > 0, source.height > 0 else { return destination }
    let scaleX = destination.width / source.width, scaleY = destination.height / source.height
    let width = min(frame.width * scaleX, destination.width)
    let height = min(frame.height * scaleY, destination.height)
    let x = destination.minX + (frame.minX - source.minX) * scaleX
    let y = destination.minY + (frame.minY - source.minY) * scaleY
    return CGRect(x: min(max(x, destination.minX), destination.maxX - width),
                  y: min(max(y, destination.minY), destination.maxY - height), width: width, height: height)
}

/// All layout geometry below is in AX coordinates (top-left, y down).
func placementFrame(_ mode: Placement, visibleFrame s: CGRect, current: CGRect) -> CGRect {
    switch mode {
    case .max: return s
    case .left: return CGRect(x: s.minX, y: s.minY, width: s.width / 2, height: s.height)
    case .right: return CGRect(x: s.midX, y: s.minY, width: s.width / 2, height: s.height)
    case .top: return CGRect(x: s.minX, y: s.minY, width: s.width, height: s.height / 2)
    case .bottom: return CGRect(x: s.minX, y: s.midY, width: s.width, height: s.height / 2)
    case .tl, .tr, .bl, .br:
        return CGRect(x: (mode == .tr || mode == .br) ? s.midX : s.minX,
                      y: (mode == .bl || mode == .br) ? s.midY : s.minY,
                      width: s.width / 2, height: s.height / 2)
    case .center:
        let w = min(current.width, s.width), h = min(current.height, s.height)
        return CGRect(x: s.midX - w / 2, y: s.midY - h / 2, width: w, height: h)
    default: return s.insetBy(dx: s.width * 0.05, dy: s.height * 0.05)
    }
}

func classifyPlacement(_ frame: CGRect, visibleFrame: CGRect) -> Placement? {
    let tx = max(12, visibleFrame.width * 0.02), ty = max(12, visibleFrame.height * 0.02)
    for mode: Placement in [.tl, .tr, .bl, .br, .left, .right, .top, .bottom, .amm, .max] {
        let target = placementFrame(mode, visibleFrame: visibleFrame, current: frame)
        if abs(frame.minX - target.minX) <= tx && abs(frame.maxX - target.maxX) <= tx &&
            abs(frame.minY - target.minY) <= ty && abs(frame.maxY - target.maxY) <= ty { return mode }
    }
    return nil
}

func nextPlacement(_ current: Placement?, fullscreen: Bool, fromFullscreen: Bool) -> Placement {
    if fullscreen { return .max }
    switch current {
    case .tl, .bl: return .left
    case .tr, .br: return .right
    case .amm: return .max
    case .max: return fromFullscreen ? .amm : .fullscreen
    default: return .amm
    }
}

func overlapScreen(_ window: CGRect, screens: [CGRect], fallback: Int = 0) -> Int {
    var best = fallback, largest: CGFloat = 0
    for (i, screen) in screens.enumerated() {
        let intersection = window.intersection(screen)
        let area = intersection.isNull ? 0 : intersection.width * intersection.height
        if area > largest { largest = area; best = i }
    }
    return best
}

/// Largest-remainder allocation avoids rounding away windows on unequal screens.
func screenQuotas(count: Int, screens: [CGRect]) -> [Int] {
    let areas = screens.map { max(0, $0.width * $0.height) }
    let total = areas.reduce(0, +)
    guard total > 0 else { return Array(repeating: 0, count: screens.count) }
    let exact = areas.map { CGFloat(count) * $0 / total }
    var quotas = exact.map { Int($0.rounded(.down)) }
    let order = exact.indices.sorted {
        let a = exact[$0] - CGFloat(quotas[$0]), b = exact[$1] - CGFloat(quotas[$1])
        return a == b ? $0 < $1 : a > b
    }
    for i in order.prefix(count - quotas.reduce(0, +)) { quotas[i] += 1 }
    return quotas
}

func tileAssignments(frames: [CGRect], screens: [CGRect], visibleFrames: [CGRect]) -> [Int] {
    guard !screens.isEmpty else { return [] }
    var assignments = frames.map { overlapScreen($0, screens: screens) }
    let quotas = screenQuotas(count: frames.count, screens: visibleFrames)
    var counts = screens.indices.map { i in assignments.filter { $0 == i }.count }
    while let source = screens.indices.filter({ counts[$0] > quotas[$0] }).max(by: {
        let a = counts[$0] - quotas[$0], b = counts[$1] - quotas[$1]
        return a == b ? $0 > $1 : a < b
    }), let destination = screens.indices.filter({ counts[$0] < quotas[$0] }).max(by: {
        let a = quotas[$0] - counts[$0], b = quotas[$1] - counts[$1]
        return a == b ? $0 > $1 : a < b
    }) {
        let window = frames.indices.filter { assignments[$0] == source }.min {
            let a = frames[$0].width * frames[$0].height, b = frames[$1].width * frames[$1].height
            return a == b ? $0 < $1 : a < b
        }!
        assignments[window] = destination
        counts[source] -= 1; counts[destination] += 1
    }
    return assignments
}

func tileFrames(count: Int, visibleFrame s: CGRect, gap: CGFloat = 6) -> [CGRect] {
    guard count > 0, s.width > 0, s.height > 0 else { return [] }
    let columns = min(count, max(1, Int(ceil(sqrt(CGFloat(count) * s.width / s.height)))))
    let rows = Int(ceil(Double(count) / Double(columns)))
    let height = max(0, (s.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
    return (0..<count).map { index in
        let row = index / columns, column = index % columns
        let inRow = min(columns, count - row * columns)
        let width = max(0, (s.width - gap * CGFloat(inRow - 1)) / CGFloat(inRow))
        return CGRect(x: s.minX + CGFloat(column) * (width + gap),
                      y: s.minY + CGFloat(row) * (height + gap), width: width, height: height)
    }
}

struct PlacementState: Codable {
    let windowKey: String
    let last: String
    let fromFullscreen: Bool
    let t: TimeInterval

    func matches(_ key: String, now: TimeInterval) -> Bool {
        windowKey == key && t <= now && now - t <= 600
    }
}
