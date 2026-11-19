import AppKit

// swift Tests/OverlaySimulation.swift center|menu|corner|edge|bottom|group|back|rapid|spam|burst|bench|reopen|movie|hide
// Posts only navigation notifications; never executes a bind or edits config.
let command = CommandLine.arguments.dropFirst().first ?? "center"
let url = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/Leader Key/config.json")
let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
let actions = config["actions"] as! [[String: Any]]
let group = actions.first { ($0["key"] as? String) == "s" && $0["actions"] != nil }
  ?? actions.first { $0["actions"] != nil }!
let key = group["key"] as! String
let nested = (group["actions"] as? [[String: Any]])?.first { $0["actions"] != nil }?["key"] as? String
func post(_ state: String, _ path: String = "", wait: Double = 0.04) {
  DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.machinespirit.leader.nav"), object: nil,
    userInfo: ["state": state, "path": path, "screen": "0,0,1,1"], deliverImmediately: true)
  if wait > 0 { RunLoop.current.run(until: Date().addingTimeInterval(wait)) }
}
func warp(_ point: CGPoint) {
  let mainTop = NSScreen.screens[0].frame.maxY
  CGWarpMouseCursorPosition(CGPoint(x: point.x, y: mainTop - point.y))
  RunLoop.current.run(until: Date().addingTimeInterval(0.06))
}
let screen = NSScreen.main!
let visible = screen.frame
print("screen=\(screen.frame) visible=\(visible) group=\(key)")
switch command {
case "center", "corner", "edge", "bottom", "menu":
  post("hidden")
  RunLoop.current.run(until: Date().addingTimeInterval(0.15))
  let point: CGPoint
  if command == "menu" { point = CGPoint(x: visible.minX + 180, y: visible.maxY - 12) }
  else if command == "corner" { point = CGPoint(x: visible.minX + 24, y: visible.maxY - 24) }
  else if command == "bottom" { point = CGPoint(x: visible.maxX - 24, y: visible.minY + 24) }
  else if command == "edge" { point = CGPoint(x: visible.maxX - 24, y: visible.midY) }
  else { point = CGPoint(x: visible.midX, y: visible.midY) }
  warp(point)
  post("shown")
case "group":
  // Moving the cursor on navigation must not move the existing panel/focus.
  warp(CGPoint(x: visible.midX + 100, y: visible.midY + 100))
  post("shown", key)
case "back": post("shown")
case "spam":
  post("hidden", wait: 0.15)
  warp(CGPoint(x: visible.midX, y: visible.midY))
  for _ in 0..<50 { post("shown", wait: 0); post("hidden", wait: 0) }
  for i in 0..<50 { post("shown", i % 2 == 0 ? key : "", wait: 0) }
  post("shown", key, wait: 0)
case "burst":
  for i in 0..<80 {
    post("shown", i % 3 == 0 ? "" : (i % 3 == 1 ? key : key + "/" + (nested ?? key)), wait: 0.06)
  }
  post("hidden")
case "bench":
  warp(CGPoint(x: visible.midX, y: visible.midY))
  for _ in 0..<15 {
    post("hidden", wait: 0.15)
    CGWarpMouseCursorPosition(CGPoint(x: visible.midX, y: NSScreen.screens[0].frame.maxY - visible.midY))
    post("shown", wait: 0.2)
  }
  post("hidden")
case "rapid":
  for _ in 0..<5 {
    post("shown", key)
    if let nested { post("shown", key + "/" + nested) }
    post("shown")
    post("hidden")
    post("shown", key)
  }
case "reopen":
  post("hidden")
  RunLoop.current.run(until: Date().addingTimeInterval(0.15))
  warp(CGPoint(x: visible.midX, y: visible.midY))
  post("shown")
  RunLoop.current.run(until: Date().addingTimeInterval(0.3))
  post("hidden") // returns 40ms into the 90ms close
  CGWarpMouseCursorPosition(CGPoint(x: visible.minX + 24,
    y: NSScreen.screens[0].frame.maxY - visible.maxY + 24))
  post("shown", key)
case "movie":
  post("hidden")
  RunLoop.current.run(until: Date().addingTimeInterval(0.2))
  warp(CGPoint(x: visible.midX, y: visible.midY))
  post("shown")
  RunLoop.current.run(until: Date().addingTimeInterval(0.4))
  post("shown", key)
  RunLoop.current.run(until: Date().addingTimeInterval(0.4))
  post("shown")
  RunLoop.current.run(until: Date().addingTimeInterval(0.4))
  post("hidden")
case "hide": post("hidden")
default: fatalError("Unknown command")
}
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerName as String] as? String) == "MachineSpirit" {
  print("overlay bounds=\(window[kCGWindowBounds as String] ?? "?") alpha=\(window[kCGWindowAlpha as String] ?? "?") level=\(window[kCGWindowLayer as String] ?? "?")")
}
print("mouse=\(NSEvent.mouseLocation)")
