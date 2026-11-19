import Foundation
import MachineSpiritKit
@testable import MachineSpirit

// In-memory preferences: this harness never writes ~/Library or real defaults.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
  private var values: [String: Any] = [:]
  override func object(forKey key: String) -> Any? { values[key] }
  override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
  override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@main struct StatsSmoke {
  @MainActor static func main() async throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let url = directory.appendingPathComponent("stats-test.json")
    try? FileManager.default.removeItem(at: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let defaults = MemoryDefaults()
    let store = StatsStore(defaults: defaults, url: url)
    store.record(path: "a", windowPlacement: false)
    store.flush()
    precondition(store.snapshot.totalFires == 0 && !FileManager.default.fileExists(atPath: url.path))
    defaults.set(true, forKey: "msStatsEnabled")
    store.record(path: "a", windowPlacement: false)
    store.record(path: "a/m", windowPlacement: true)
    precondition(store.snapshot.totalFires == 2 && store.snapshot.estimatedSecondsSaved == 6.5)
    precondition(!FileManager.default.fileExists(atPath: url.path), "Debounce wrote immediately")
    try await Task.sleep(for: .seconds(9))
    precondition(!FileManager.default.fileExists(atPath: url.path), "Debounce shorter than 10s")
    try await Task.sleep(for: .seconds(1.5))
    let saved = try JSONDecoder().decode(BindStats.self, from: Data(contentsOf: url))
    precondition(saved == store.snapshot)
    let reopened = StatsStore(defaults: defaults, url: url)
    precondition(reopened.snapshot == saved)
    store.record(path: "a", windowPlacement: false)
    store.disable()
    store.flush()
    let disabledSave = try JSONDecoder().decode(BindStats.self, from: Data(contentsOf: url))
    precondition(disabledSave == saved)
    store.reset()
    precondition(!FileManager.default.fileExists(atPath: url.path) && store.snapshot.totalFires == 0)
    defaults.set(true, forKey: "msStatsEnabled")
    store.record(path: "a", windowPlacement: false)
    store.reset()
    try await Task.sleep(for: .seconds(10.2))
    precondition(!FileManager.default.fileExists(atPath: url.path), "Cancelled write resurrected reset stats")
    let today = Date()
    var stats = BindStats()
    for i in 0..<80 {
      let date = Calendar.current.date(byAdding: .day, value: -i, to: today)!
      stats.record(path: "a/\(i)", windowPlacement: i % 2 == 0, at: date)
    }
    // Generate old-to-new as well; prune must use the write day, not last fire.
    let persisted = stats.persisted(at: today)
    precondition(persisted.firesPerPath.count == 50)
    precondition(persisted.perDay.count <= 60)
    var history = BindStats()
    for i in (0..<80).reversed() {
      history.record(path: "a", windowPlacement: false,
        at: Calendar.current.date(byAdding: .day, value: -i, to: today)!)
    }
    precondition(history.perDay.count == 60 && history.totalFires == 80)
    precondition(StatsStore.isWindowPlacement(Node(id: "x", action: .command("~/bin/ms win place smart"))))
    precondition(StatsStore.isWindowPlacement(Node(id: "x", action: .command("\"$HOME/bin/ms\" win place left"))))
    precondition(!StatsStore.isWindowPlacement(Node(id: "x", action: .command("~/bin/ms win cycle"))))
    let knobs = OverlayFX(defaults: defaults)
    precondition(knobs.shockwave && !knobs.curvedTraces && knobs.closeDuration == knobs.openingDuration / 2)
    defaults.set(false, forKey: "msFX.letterPop")
    defaults.set(-3.0, forKey: "msFX.popDuration")
    precondition(!OverlayFX(defaults: defaults).letterPop && OverlayFX(defaults: defaults).popDuration == 0)
    precondition(SkullMark.path().boundingBoxOfPath.height == 44)
    print("PASS opt-in, 10s debounce, disk round-trip, disable/reset cancellation, top 50, 60 days, estimates, FX knobs, skull geometry")
  }
}
