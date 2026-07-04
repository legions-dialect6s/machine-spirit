// shield-fx.swift — the busy-pane shield's visual flare / shatter overlay.
//
//   shield-fx <level>     1|2 = escalating shield flare,  3 = shatter + break
//
// Draws a fullscreen, transparent, CLICK-THROUGH, non-activating overlay that
// plays a short Core Animation effect and then terminates itself. It never
// becomes key/main, ignores all mouse events, and force-exits after a hard
// deadline — so it cannot steal focus, block input, or linger if something goes
// wrong. Purely additive eye-candy: if it's missing or fails, the shield still
// works (pane-shield.py calls it fire-and-forget).
//
// v1 is a STYLIZED vector effect (HUD rings + glass shards), not a shatter of
// the real screen pixels — that would need Screen Recording permission and
// pixel-orientation handling. Real-pixel shatter is noted as a future item.
//
// Build:  swiftc -O shield-fx.swift -o ~/bin/shield-fx
import AppKit
import QuartzCore

let level = max(1, min(3, Int(CommandLine.arguments.dropFirst().first ?? "1") ?? 1))

// Palette — cyber shield: cyan core, warming toward amber as it overloads.
func cyan(_ a: CGFloat) -> CGColor { CGColor(red: 0.30, green: 0.95, blue: 1.0, alpha: a) }
func amber(_ a: CGFloat) -> CGColor { CGColor(red: 1.0, green: 0.72, blue: 0.28, alpha: a) }
func white(_ a: CGFloat) -> CGColor { CGColor(red: 1, green: 1, blue: 1, alpha: a) }
func accent(_ a: CGFloat) -> CGColor { level >= 2 ? amber(a) : cyan(a) }

final class Overlay: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }
        let f = screen.frame
        window = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true                 // click-through
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: f.size))
        view.wantsLayer = true
        view.layer?.isOpaque = false
        window.contentView = view
        window.orderFrontRegardless()                    // show WITHOUT activating

        let root = view.layer!
        let W = f.size.width, H = f.size.height
        let center = CGPoint(x: W / 2, y: H / 2)

        if level >= 3 {
            shatter(root, W: W, H: H, center: center)
        } else {
            flare(root, center: center, maxR: min(W, H) * (level == 2 ? 0.42 : 0.30))
        }

        // Hard self-destruct deadline — belt and suspenders against any hang.
        let life = level >= 3 ? 0.95 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + life) { NSApp.terminate(nil) }
    }

    // --- levels 1 & 2: expanding hexagonal energy ring(s) + edge vignette pulse
    func flare(_ root: CALayer, center: CGPoint, maxR: CGFloat) {
        let rings = level == 2 ? 2 : 1
        for i in 0..<rings {
            let ring = CAShapeLayer()
            ring.path = hexPath(center: center, radius: maxR)
            ring.fillColor = accent(0.05)
            ring.strokeColor = accent(0.95)
            ring.lineWidth = level == 2 ? 6 : 4
            ring.shadowColor = accent(1)
            ring.shadowRadius = 18
            ring.shadowOpacity = 0.9
            ring.opacity = 0
            root.addSublayer(ring)

            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.15
            grow.toValue = 1.0
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.0, 1.0, 0.0]
            fade.keyTimes = [0, 0.25, 1.0]
            let g = CAAnimationGroup()
            g.animations = [grow, fade]
            g.duration = 0.42
            g.beginTime = CACurrentMediaTime() + Double(i) * 0.06
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.fillMode = .forwards
            g.isRemovedOnCompletion = false
            // scale about the ring's center
            ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            ring.frame = root.bounds
            ring.path = hexPath(center: center, radius: maxR)
            ring.add(g, forKey: "flare")
        }
        // faint full-screen tint pulse
        let tint = CALayer()
        tint.frame = root.bounds
        tint.backgroundColor = accent(1)
        tint.opacity = 0
        root.addSublayer(tint)
        let p = CAKeyframeAnimation(keyPath: "opacity")
        p.values = [0.0, level == 2 ? 0.16 : 0.10, 0.0]
        p.keyTimes = [0, 0.2, 1.0]
        p.duration = 0.4
        p.isRemovedOnCompletion = false
        p.fillMode = .forwards
        tint.add(p, forKey: "tint")
    }

    // --- level 3: white flash -> radial crack lines -> glass shards burst out
    func shatter(_ root: CALayer, W: CGFloat, H: CGFloat, center: CGPoint) {
        // white flash
        let flash = CALayer()
        flash.frame = root.bounds
        flash.backgroundColor = white(1)
        flash.opacity = 0
        root.addSublayer(flash)
        let fa = CAKeyframeAnimation(keyPath: "opacity")
        fa.values = [0.0, 0.85, 0.0]
        fa.keyTimes = [0, 0.04, 0.35]
        fa.duration = 0.5
        fa.isRemovedOnCompletion = false
        fa.fillMode = .forwards
        flash.add(fa, forKey: "flash")

        // crack lines radiating from center
        let cracks = CAShapeLayer()
        let cp = CGMutablePath()
        for _ in 0..<14 {
            let ang = CGFloat.random(in: 0..<(2 * .pi))
            let len = CGFloat.random(in: min(W, H) * 0.25 ... max(W, H) * 0.6)
            cp.move(to: center)
            let mid = CGPoint(x: center.x + cos(ang) * len * 0.5 + CGFloat.random(in: -30...30),
                              y: center.y + sin(ang) * len * 0.5 + CGFloat.random(in: -30...30))
            cp.addLine(to: mid)
            cp.addLine(to: CGPoint(x: center.x + cos(ang) * len, y: center.y + sin(ang) * len))
        }
        cracks.path = cp
        cracks.strokeColor = white(0.9)
        cracks.fillColor = nil
        cracks.lineWidth = 2
        cracks.shadowColor = cyan(1); cracks.shadowRadius = 6; cracks.shadowOpacity = 1
        cracks.opacity = 0
        root.addSublayer(cracks)
        let cf = CAKeyframeAnimation(keyPath: "opacity")
        cf.values = [0.0, 1.0, 0.0]; cf.keyTimes = [0, 0.12, 0.5]
        cf.duration = 0.55; cf.isRemovedOnCompletion = false; cf.fillMode = .forwards
        cracks.add(cf, forKey: "cracks")

        // glass shards from a jittered grid, bursting outward with gravity
        let cols = 8, rows = 5
        for r in 0..<rows {
            for c in 0..<cols {
                let jx = CGFloat.random(in: -0.35...0.35), jy = CGFloat.random(in: -0.35...0.35)
                let x = (CGFloat(c) + 0.5 + jx) / CGFloat(cols) * W
                let y = (CGFloat(r) + 0.5 + jy) / CGFloat(rows) * H
                let s = min(W, H) * CGFloat.random(in: 0.05...0.11)
                let pts = (0..<3).map { _ in
                    CGPoint(x: x + CGFloat.random(in: -s...s), y: y + CGFloat.random(in: -s...s))
                }
                addShard(root, points: pts, center: center)
            }
        }
    }

    func addShard(_ root: CALayer, points: [CGPoint], center: CGPoint) {
        let xs = points.map { $0.x }, ys = points.map { $0.y }
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let bw = max(1, maxX - minX), bh = max(1, maxY - minY)
        let centroid = CGPoint(x: (xs.reduce(0,+))/3, y: (ys.reduce(0,+))/3)

        let shard = CAShapeLayer()
        shard.bounds = CGRect(x: 0, y: 0, width: bw, height: bh)
        shard.position = centroid
        shard.anchorPoint = CGPoint(x: (centroid.x - minX)/bw, y: (centroid.y - minY)/bh)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: points[0].x - minX, y: points[0].y - minY))
        path.addLine(to: CGPoint(x: points[1].x - minX, y: points[1].y - minY))
        path.addLine(to: CGPoint(x: points[2].x - minX, y: points[2].y - minY))
        path.closeSubpath()
        shard.path = path
        shard.fillColor = cyan(0.16)
        shard.strokeColor = white(0.85)
        shard.lineWidth = 1.2
        shard.shadowColor = cyan(1); shard.shadowRadius = 5; shard.shadowOpacity = 0.8
        root.addSublayer(shard)

        // direction: outward from screen center, plus a downward gravity bias
        var dx = centroid.x - center.x, dy = centroid.y - center.y
        let mag = max(1, hypot(dx, dy)); dx /= mag; dy /= mag
        let dist = CGFloat.random(in: 260...1000)
        let tx = dx * dist, ty = dy * dist - CGFloat.random(in: 120...420)   // gravity pulls down

        let move = CAKeyframeAnimation(keyPath: "position")
        let p0 = centroid
        let p1 = CGPoint(x: centroid.x + tx * 0.5, y: centroid.y + ty * 0.5 + 60)
        let p2 = CGPoint(x: centroid.x + tx, y: centroid.y + ty - 240)       // arc
        let mp = CGMutablePath(); mp.move(to: p0); mp.addQuadCurve(to: p2, control: p1)
        move.path = mp
        let spin = CABasicAnimation(keyPath: "transform.rotation")
        spin.fromValue = 0; spin.toValue = CGFloat.random(in: -2.4...2.4)
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1.0; shrink.toValue = CGFloat.random(in: 0.4...0.8)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1.0, 1.0, 0.0]; fade.keyTimes = [0, 0.55, 1.0]

        let g = CAAnimationGroup()
        g.animations = [move, spin, shrink, fade]
        g.duration = 0.8
        g.beginTime = CACurrentMediaTime() + Double.random(in: 0...0.06)
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        shard.add(g, forKey: "burst")
    }

    func hexPath(center: CGPoint, radius: CGFloat) -> CGPath {
        let p = CGMutablePath()
        for i in 0..<6 {
            let a = CGFloat(i) / 6 * 2 * .pi - .pi / 2
            let pt = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)          // no Dock icon, no menu, never frontmost
let delegate = Overlay()
app.delegate = delegate
app.run()
