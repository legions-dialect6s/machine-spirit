import Foundation
import MachineSpiritKit
import Observation

struct BindStats: Codable, Equatable {
  var totalFires = 0
  var firesPerPath: [String: Int] = [:]
  var perDay: [String: Int] = [:]
  var estimatedSecondsSaved: Double = 0

  static func day(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }

  var timeSavedLabel: String {
    if estimatedSecondsSaved >= 3600 { return String(format: "%.1f h", estimatedSecondsSaved / 3600) }
    if estimatedSecondsSaved >= 60 { return String(format: "%.1f min", estimatedSecondsSaved / 60) }
    return String(format: "%.1f s", estimatedSecondsSaved)
  }

  var topPaths: [(key: String, value: Int)] {
    firesPerPath.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
  }

  mutating func prune(at date: Date, calendar: Calendar = .current) {
    let cutoff = Self.day(calendar.date(byAdding: .day, value: -59, to: date)!, calendar: calendar)
    let today = Self.day(date, calendar: calendar)
    perDay = perDay.filter { $0.key >= cutoff && $0.key <= today }
  }

  mutating func record(path: String, windowPlacement: Bool, at date: Date) {
    totalFires += 1
    firesPerPath[path, default: 0] += 1
    perDay[Self.day(date), default: 0] += 1
    estimatedSecondsSaved += windowPlacement ? 4 : 2.5
    prune(at: date)
  }

  func persisted(at date: Date) -> Self {
    var copy = self
    copy.prune(at: date)
    copy.firesPerPath = Dictionary(uniqueKeysWithValues: topPaths.prefix(50).map { ($0.key, $0.value) })
    return copy
  }
}

/// Opt-in, day-resolution key paths only. No payloads, fine timestamps, network,
/// repeating timer, or work when disabled. The sole delayed task exists only
/// after a fire and is cancelled by another fire, reset, disable or shutdown.
@Observable @MainActor
final class StatsStore {
  private(set) var snapshot = BindStats()
  private(set) var enabled: Bool
  private(set) var persistenceError: String?
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let url: URL
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private var dirty = false

  init(defaults: UserDefaults = .standard, url: URL? = nil) {
    self.defaults = defaults
    self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/MachineSpirit/stats.json")
    enabled = defaults.bool(forKey: "msStatsEnabled")
    if enabled { load() }
  }

  private func load() {
    if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(BindStats.self, from: data) {
      snapshot = saved.persisted(at: Date())
    }
  }

  /// Called exclusively by the distributed fired handler, after model validation.
  func record(path: String, windowPlacement: Bool, at date: Date = Date()) {
    let optedIn = defaults.bool(forKey: "msStatsEnabled")
    if optedIn != enabled {
      enabled = optedIn
      if enabled { load() }
      else { pending?.cancel(); pending = nil; dirty = false }
    }
    guard enabled, !path.isEmpty else { return }
    snapshot.record(path: path, windowPlacement: windowPlacement, at: date)
    dirty = true
    pending?.cancel()
    pending = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      guard let self else { return }
      self.pending = nil
      self.flush()
    }
  }

  func flush() {
    pending?.cancel(); pending = nil
    guard dirty, enabled, defaults.bool(forKey: "msStatsEnabled") else { return }
    do {
      let data = try JSONEncoder().encode(snapshot.persisted(at: Date()))
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      dirty = false; persistenceError = nil
    } catch { persistenceError = "Local stats could not be saved." }
  }

  func reset() {
    pending?.cancel(); pending = nil; dirty = false
    snapshot = BindStats()
    do {
      if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
      persistenceError = nil
    } catch { persistenceError = "Local stats could not be reset." }
  }

  func disable() {
    pending?.cancel(); pending = nil; dirty = false
    defaults.set(false, forKey: "msStatsEnabled")
    enabled = false
  }

  static func isWindowPlacement(_ node: Node) -> Bool {
    if node.action?.windowAction != nil { return true }
    guard case .command(let command) = node.action else { return false }
    return command.range(of: #"(?:^|[\s/])ms[\"']?\s+win\s+place(?:\s|$)"#,
                         options: .regularExpression) != nil
  }
}
