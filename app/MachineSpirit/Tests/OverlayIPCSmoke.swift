import AppKit
import QuartzCore
import MachineSpiritKit
@testable import MachineSpirit

final class IPCDefaults: UserDefaults, @unchecked Sendable {
  var optedIn = false
  override func bool(forKey key: String) -> Bool { key == "msStatsEnabled" && optedIn }
  override func set(_ value: Any?, forKey key: String) { if key == "msStatsEnabled" { optedIn = value as? Bool ?? false } }
}

/// Real DistributedNotificationCenter delivery to the production delegate,
/// using a private namespace so the installed app never sees the simulation.
/// Optional first argument is a scratch directory for overlay-window captures.
@main struct OverlayIPCSmoke {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let defaults = IPCDefaults()
    let stats = StatsStore(defaults: defaults, url: URL(fileURLWithPath: "/dev/null"))
    let state = AppState(stats: stats)
    state.model = Node(id: "root", children: [
      Node(id: "root/a", key: "a", label: "applications", children: [
        Node(id: "root/a/m", key: "m", label: "machine spirit", action: .command("true")),
        Node(id: "root/a/s", key: "s", label: "shell", action: .command("true"))]),
      Node(id: "root/w", key: "w", label: "windows", children: [
        Node(id: "root/w/space", key: "space", label: "smart placement", action: .command("~/bin/ms win place smart"))]),
      Node(id: "root/t", key: "t", label: "terminal")])
    let delegate = AppDelegate(state: state)
    let prefix = "com.machinespirit.overlay-test.\(UUID().uuidString)"
    delegate.installOverlayObservers(prefix: prefix)
    let panel = NSApp.windows.first { $0 is NSPanel }!
    func pump(_ seconds: Double = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func send(_ suffix: String, _ info: [String: String]) {
      DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("\(prefix).\(suffix)"), object: nil, userInfo: info, deliverImmediately: true)
    }
    func capture(_ name: String) throws {
      guard CommandLine.arguments.count > 1 else { return }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-l", String(panel.windowNumber), CommandLine.arguments[1] + "/" + name + ".png"]
      try process.run(); process.waitUntilExit()
      precondition(process.terminationStatus == 0, "screencapture needs Screen Recording permission")
    }
    send("nav", ["state": "shown", "path": ""]); pump(0.6)
    precondition(state.overlayVisible && state.overlayNodeID == "root")
    print("DISPLAY scale=\(panel.screen?.backingScaleFactor ?? 0) size=\(panel.frame.size)"); fflush(stdout)
    try capture("root")
    send("nav", ["state": "shown", "path": "a"]); pump()
    send("nav", ["state": "shown", "path": "a/m"]); pump()
    send("feedback", ["kind": "miss", "path": "a/m"]); pump(0.06)
    try capture("miss")
    send("feedback", ["kind": "back", "path": "a"]); pump()
    precondition(state.overlayNodeID == "root/a")
    send("nav", ["state": "hold", "path": "a/m"]); pump()
    send("fired", ["path": "a/m"]); pump()
    send("feedback", ["kind": "hold", "path": "a/m", "n": "1", "key": "m"]); pump()
    send("feedback", ["kind": "done", "path": "a/m"]); pump(0.08)
    try capture("done")
    pump(0.6)
    precondition(state.overlayVisible && state.overlayNodeID == "root/a/m" && panel.alphaValue == 1)
    precondition(!panel.canBecomeKey && !panel.canBecomeMain && NSApp.keyWindow !== panel)
    precondition(stats.snapshot.totalFires == 0)
    try capture("hold")
    print("VISIBLE settled pid=\(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
    if CommandLine.arguments.count > 1 { pump(8) }
    send("nav", ["state": "hidden"]); pump()
    precondition(!state.overlayVisible && panel.alphaValue == 0 && panel.ignoresMouseEvents)
    print("HIDDEN settled"); fflush(stdout)
    if CommandLine.arguments.count > 1 { pump(8) }
    defaults.optedIn = true
    send("fired", ["path": "a/m"]); pump(0.05)
    precondition(stats.snapshot.totalFires == 1 && stats.snapshot.firesPerPath == ["a/m": 1])
    delegate.application(NSApp, open: [URL(string: "machinespirit://fired?path=a/m")!])
    precondition(stats.snapshot.totalFires == 1, "Legacy URL double-counted stats")
    stats.disable()
    state.selectedNodeID = "root/a/m"; state.pan = CGSize(width: 71, height: -53); state.zoom = 1.7
    state.closeBoard(persist: false)
    precondition(state.selectedNodeID == "root/a/m" && state.pan.width == 71 && state.pan.height == -53 && state.zoom == 1.7)
    DistributedNotificationCenter.default().removeObserver(delegate)
    panel.orderOut(nil)
    print("PASS real IPC shown → a → a/m → miss → back → hold → done → hidden; non-key panel; stats opt-out; viewport preserved")
  }
}
