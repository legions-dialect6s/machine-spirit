import Foundation

// Run from app/MachineSpirit:
// swiftc -swift-version 6 -parse-as-library Sources/ConfigWatcher.swift \
//   Tests/ConfigWatcherSmoke.swift -o DerivedData/config-watch-smoke
// DerivedData/config-watch-smoke
@main
struct ConfigWatcherSmoke {
  @MainActor static func main() async throws {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("DerivedData/config-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("new/config.json")
    var changes = 0
    let watcher = ConfigWatcher(url: file) { changes += 1 }
    defer { watcher.stop() }

    func waitForChange(after previous: Int, _ label: String) async throws {
      for _ in 0..<100 {
        if changes > previous { print("PASS \(label)"); return }
        try await Task.sleep(for: .milliseconds(20))
      }
      fatalError("No event: \(label)")
    }

    try await Task.sleep(for: .milliseconds(120))
    precondition(changes == 0, "Idle watcher emitted events")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("one".utf8).write(to: file)
    try await waitForChange(after: 0, "missing parent and first config creation")
    var previous = changes
    try Data("two longer".utf8).write(to: file)
    try await waitForChange(after: previous, "in-place write")
    previous = changes
    try Data("atomic".utf8).write(to: file, options: .atomic)
    try await waitForChange(after: previous, "atomic replacement")
    previous = changes
    try FileManager.default.removeItem(at: file)
    try await waitForChange(after: previous, "deletion")
    previous = changes
    try Data("recreated".utf8).write(to: file, options: .atomic)
    try await waitForChange(after: previous, "recreation")
    previous = changes
    try Data("pen write".utf8).write(to: file, options: .atomic)
    watcher.acknowledgeCurrent()
    try await Task.sleep(for: .milliseconds(200))
    precondition(changes == previous, "Acknowledged write echoed")
    print("PASS own-write suppression")
    previous = changes
    let parent = file.deletingLastPathComponent()
    try FileManager.default.moveItem(at: parent, to: directory.appendingPathComponent("old"))
    try await waitForChange(after: previous, "parent rename")
    previous = changes
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try Data("restored parent".utf8).write(to: file)
    try await waitForChange(after: previous, "parent recreation")
    watcher.stop()
    previous = changes
    try Data("stopped".utf8).write(to: file)
    try await Task.sleep(for: .milliseconds(200))
    precondition(changes == previous, "Stopped watcher emitted events")
    print("PASS stop; no live config touched")
  }
}
