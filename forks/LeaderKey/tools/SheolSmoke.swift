// Compile with Leader Key/SheolReader.swift. Read-only comparison with the existing helpers.
import Cocoa

@main
struct SheolSmoke {
  static func helper(_ name: String) -> [[String: Any]] {
    let process = Process()
    process.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "bin/" + name)
    process.arguments = ["list", "--json"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try! process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (try! JSONSerialization.jsonObject(with: data)) as! [[String: Any]]
  }
  static func main() {
    let format = "S\u{1f}#{session_name}\u{1f}#{session_attached}"
    let text = TmuxReader.read([
      "list-sessions", "-F", format, ";", "list-panes", "-a", "-F", "P\u{1f}#{pane_tty}", ";",
      "list-clients", "-F", "P\u{1f}#{client_tty}",
    ])!
    let lines = text.split(separator: "\n").map { $0.components(separatedBy: "\u{1f}") }
    let sessions = lines.filter { $0.count == 3 && $0[0] == "S" }
    let tmuxTTYs = Set(lines.filter { $0.count == 2 && $0[0] == "P" }.map { $0[1] })
    let baseline = helper("sheol-core")
    precondition(Set(sessions.map { $0[1] }) == Set(baseline.compactMap { $0["name"] as? String }))
    let live = sessions.filter { Int($0[2])! > 0 }.count
    let dead = sessions.count - live
    precondition(live == baseline.filter { ($0["attached"] as? Int ?? 0) > 0 }.count)
    let pid = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.googlecode.iterm2"
    ).first?.processIdentifier
    let terminals = pid.flatMap { TerminalReader.readITerm(pid: $0) } ?? []
    let others = TerminalReader.otherTerminals(excluding: tmuxTTYs.union(terminals.map(\.tty)))
    let plain = (terminals + others).filter {
      !tmuxTTYs.contains($0.tty) && !$0.name.hasPrefix("tmux")
    }.count
    let terminalBaseline = helper("terminals-core").filter { !($0["isTmux"] as? Bool ?? false) }
      .count
    precondition(
      plain == terminalBaseline,
      "native/helper counts differ; recheck for a concurrent terminal change")
    print(
      "PASS native vs existing helpers: \(plain)·\(live)·\(dead), no double-counted tmux terminals")
  }
}
