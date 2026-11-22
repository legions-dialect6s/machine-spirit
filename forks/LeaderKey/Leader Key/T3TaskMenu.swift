import Cocoa
import SQLite3

/// A bounded, read-only view of this Mac's T3 v2 task projections.
/// No server tokens, message contents, or event replay are needed.
enum T3TaskRegistry {
  struct Entry: Equatable {
    let title: String
    let working: Bool
    let url: URL
  }

  private struct Runtime: Decodable {
    let pid: Int32
    let startedAt: String

    var isLive: Bool {
      guard pid > 0 else { return false }
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
      let format = ISO8601DateFormatter()
      format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      guard let started = format.date(from: startedAt) ?? ISO8601DateFormatter().date(from: startedAt) else { return false }
      // A different process can inherit a crashed server's PID.
      return Double(info.pbi_start_tvsec) <= started.timeIntervalSince1970
    }
  }

  static var directory: URL {
    let home = ProcessInfo.processInfo.environment["T3CODE_HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3")
    return home.appendingPathComponent("userdata")
  }

  static func localEntries() -> [Entry]? {
    let directory = self.directory
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("server-runtime.json")),
          let runtime = try? JSONDecoder().decode(Runtime.self, from: data),
          runtime.isLive,
          let raw = try? String(contentsOf: directory.appendingPathComponent("environment-id"), encoding: .utf8),
          let environment = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return read(file: directory.appendingPathComponent("statev2.sqlite"), environment: environment)
  }

  static func read(file: URL, environment: UUID) -> [Entry]? {
    var database: OpaquePointer?
    let opened = sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
    defer { sqlite3_close(database) }
    guard opened == SQLITE_OK else { return nil }
    sqlite3_busy_timeout(database, 100)
    // Latest ordinal is indexed by thread. Old attempts may still say "running".
    // Child forks and delegated threads are nested under their own top-level task.
    let sql = """
      SELECT t.thread_id, t.title,
             r.status IN ('preparing','starting','running') AND r.completed_at IS NULL
               AND NOT EXISTS (
                 SELECT 1 FROM orchestration_v2_projection_runtime_requests q
                  WHERE q.thread_id = t.thread_id AND q.status = 'pending' AND q.resolved_at IS NULL
               )
               AND NOT EXISTS (
                 SELECT 1 FROM orchestration_v2_projection_subagents child
                   JOIN orchestration_v2_projection_runtime_requests q ON q.thread_id = child.child_thread_id
                  WHERE child.thread_id = t.thread_id AND child.run_id = r.run_id
                    AND child.completed_at IS NULL AND q.status = 'pending' AND q.resolved_at IS NULL
               ) AS working
        FROM orchestration_v2_projection_threads t
        LEFT JOIN orchestration_v2_projection_runs r ON r.run_id = (
          SELECT latest.run_id FROM orchestration_v2_projection_runs latest
           WHERE latest.thread_id = t.thread_id ORDER BY latest.ordinal DESC LIMIT 1
        )
       WHERE t.archived_at IS NULL AND t.deleted_at IS NULL
         AND json_extract(t.payload_json, '$.lineage.parentThreadId') IS NULL
         AND coalesce(json_extract(t.payload_json, '$.settledOverride'), '') <> 'settled'
         AND (json_extract(t.payload_json, '$.settledAt') IS NULL
              OR json_extract(t.payload_json, '$.settledOverride') = 'active')
         AND coalesce(julianday(json_extract(t.payload_json, '$.snoozedUntil')), 0) <= julianday('now')
       ORDER BY working DESC, t.updated_at DESC, t.thread_id
      """
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    var entries: [Entry] = []
    var step = sqlite3_step(statement)
    while step == SQLITE_ROW {
      guard let rawID = sqlite3_column_text(statement, 0),
            let rawTitle = sqlite3_column_text(statement, 1) else { return nil }
      let id = String(cString: rawID)
      guard !id.isEmpty, let segment = id.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))),
            let url = URL(string: "t3code://threads/\(environment.uuidString.lowercased())/\(segment)") else { return nil }
      entries.append(Entry(title: String(cString: rawTitle), working: sqlite3_column_int(statement, 2) != 0, url: url))
      step = sqlite3_step(statement)
    }
    return step == SQLITE_DONE ? entries : nil
  }
}

final class T3TaskMenu: NSObject, NSMenuDelegate {
  private let queue = DispatchQueue(label: "com.machinespirit.t3-tasks", qos: .utility)
  private var entries: [T3TaskRegistry.Entry]?
  private var reading = false
  private var tracking = false
  private var lastRead = -Double.infinity
  private weak var submenu: NSMenu?
  var changed: (() -> Void)?

  var counts: CompactBarState.TaskCount {
    guard let entries else { return .unavailable }
    return .counts(working: entries.filter(\.working).count, open: entries.count)
  }

  func refresh(force: Bool = false) {
    let now = ProcessInfo.processInfo.systemUptime
    guard !reading, force || now - lastRead >= 4 else { return }
    lastRead = now
    reading = true
    queue.async {
      let snapshot = T3TaskRegistry.localEntries()
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.reading = false
        guard self.entries != snapshot else { return }
        let previousCounts = self.counts
        self.entries = snapshot
        if let menu = self.submenu, !self.tracking || menu.items.first?.isEnabled == false {
          self.populate(menu)
        }
        if self.counts != previousCounts { self.changed?() }
      }
    }
  }

  func append(to menu: NSMenu) {
    let section = NSMenuItem(title: "T3 tasks", action: nil, keyEquivalent: "")
    let sub = NSMenu()
    sub.autoenablesItems = false
    sub.delegate = self
    section.submenu = sub
    menu.addItem(section)
    submenu = sub
    populate(sub)
  }

  private func populate(_ menu: NSMenu) {
    menu.removeAllItems()
    guard let entries, !entries.isEmpty else {
      let row = NSMenuItem(title: entries == nil ? "Local task data unavailable" : "No open tasks", action: nil, keyEquivalent: "")
      row.isEnabled = false
      menu.addItem(row)
      return
    }
    for entry in entries {
      let name = entry.title.isEmpty ? "Untitled task" : entry.title
      let item = NSMenuItem(title: String(name.prefix(80)), action: #selector(openTask(_:)), keyEquivalent: "")
      item.toolTip = "\(entry.working ? "Working" : "Open") · \(name)"
      item.image = NSImage(systemSymbolName: entry.working ? "circle.fill" : "circle",
                           accessibilityDescription: entry.working ? "Working" : "Open")
      item.target = self
      item.representedObject = entry.url
      menu.addItem(item)
    }
  }

  func menuWillOpen(_ menu: NSMenu) { tracking = true }
  func menuDidClose(_ menu: NSMenu) { tracking = false }

  @objc private func openTask(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    NSWorkspace.shared.open(url)
  }
}
