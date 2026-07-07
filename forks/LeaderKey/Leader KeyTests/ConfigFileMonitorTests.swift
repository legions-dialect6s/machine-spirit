import XCTest

@testable import Leader_Key

/// machine-spirit fork: the hot-reload watcher. The replace-by-rename case
/// is the load-bearing one — write-back lands configs via atomic swap, so a
/// watcher that dies with the old inode would receive exactly one change
/// ever and then go deaf.
final class ConfigFileMonitorTests: XCTestCase {
  var dir: URL!
  var file: URL!
  var monitor: ConfigFileMonitor!

  override func setUpWithError() throws {
    dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("monitor-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    file = dir.appendingPathComponent("config.json")
    try Data("{}".utf8).write(to: file)
    monitor = ConfigFileMonitor()
  }

  override func tearDownWithError() throws {
    monitor.stop()
    try? FileManager.default.removeItem(at: dir)
  }

  func testInPlaceWriteFires() throws {
    let fired = expectation(description: "change fired")
    monitor.watch(path: { self.file.path }) { fired.fulfill() }
    // Give the watch a beat to arm before the write.
    Thread.sleep(forTimeInterval: 0.2)
    try Data(#"{"edited":1}"#.utf8).write(to: file)
    wait(for: [fired], timeout: 3.0)
  }

  func testAtomicRenameFiresAndTheWatchSurvives() throws {
    var count = 0
    let first = expectation(description: "rename fired")
    let second = expectation(description: "post-rename write fired")
    monitor.watch(path: { self.file.path }) {
      count += 1
      if count == 1 { first.fulfill() }
      if count == 2 { second.fulfill() }
    }
    Thread.sleep(forTimeInterval: 0.2)

    // The write ritual: temp file beside the target, rename(2) over it.
    let temp = dir.appendingPathComponent("config.json.tmp")
    try Data(#"{"swapped":1}"#.utf8).write(to: temp)
    _ = rename(temp.path, file.path)
    wait(for: [first], timeout: 3.0)

    // The old inode is gone; only a re-armed watch sees this second write.
    try Data(#"{"swapped":2}"#.utf8).write(to: file)
    wait(for: [second], timeout: 3.0)
  }

  func testStopGoesQuiet() throws {
    let fired = expectation(description: "no change after stop")
    fired.isInverted = true
    monitor.watch(path: { self.file.path }) { fired.fulfill() }
    Thread.sleep(forTimeInterval: 0.2)
    monitor.stop()
    Thread.sleep(forTimeInterval: 0.1)
    try Data(#"{"edited":1}"#.utf8).write(to: file)
    wait(for: [fired], timeout: 1.0)
  }
}
