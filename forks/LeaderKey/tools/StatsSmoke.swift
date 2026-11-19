// swiftc SystemStats.swift MemoryPressureStatusItem.swift SMC.swift tools/StatsSmoke.swift -o /tmp/stats-smoke
import Cocoa

@main
struct StatsSmoke {
  static func main() {
    // Counter reset / primary interface change / first sample must never show a spike.
    typealias Reader = SystemStats.DetailReader
    let first = Reader.Counter(identity: "en0", down: 100, up: 200, time: 1)
    precondition(Reader.rates(first, nil).0 == "measuring…")
    let reset = Reader.Counter(identity: "en0", down: 1, up: 2, time: 2)
    precondition(Reader.rates(reset, first).0 == "measuring…")
    let changed = Reader.Counter(identity: "en1", down: 1000, up: 2000, time: 2)
    precondition(Reader.rates(changed, first).0 == "measuring…")
    let next = Reader.Counter(identity: "en0", down: 1124, up: 2248, time: 2)
    precondition(Reader.rates(next, first).0 == "1 KB/s")
    print("PASS rate baseline/reset/interface change")
    let stats = SystemStats()
    var updates = 0
    stats.onUpdate = { rows in
      updates += 1
      precondition(rows.map(\.name) == SystemStats.names)
      if updates == 2 {
        for row in rows {
          print("\(row.name): \(row.summary)")
          for detail in row.details { print("  \(detail)") }
        }
      }
    }
    // Closed means no detailed samples, even if the bar CPU is being sampled.
    stats.sampleCPU()
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    precondition(stats.detailedSamples == 0)
    stats.open()
    RunLoop.main.run(until: Date().addingTimeInterval(3.5))
    precondition(updates >= 2)
    stats.close()
    let afterClose = updates
    RunLoop.main.run(until: Date().addingTimeInterval(2.2))
    precondition(updates == afterClose && !stats.isOpen)
    stats.open()
    RunLoop.main.run(until: Date().addingTimeInterval(2.2))
    stats.close()
    precondition(updates > afterClose)
    print("PASS open/close/reopen lifecycle: \(updates) updates, none delivered while closed")
  }
}
