import Foundation

/// One tmux session as sheol-core reports it.
struct Spirit: Codable, Equatable, Identifiable {
  var name: String
  var attached: Int
  var created: Int
  var activity: Int
  var command: String

  var id: String { name }
  var isWandering: Bool { attached == 0 }

  var quietFor: String {
    let seconds = max(0, Int(Date().timeIntervalSince1970) - activity)
    let days = seconds / 86400
    let hours = (seconds % 86400) / 3600
    let minutes = (seconds % 3600) / 60
    if days > 0 { return "\(days)d\(hours)h" }
    if hours > 0 { return "\(hours)h\(minutes)m" }
    return "\(minutes)m"
  }
}

/// The app's ONLY door to tmux: everything goes through bin/sheol-core —
/// the same verbs the TUI uses, so ledger and altar can never disagree.
/// The app never talks to tmux directly.
enum SheolService {
  /// Prefer the live ~/bin install; fall back to the repo copy beside this
  /// source file (dev builds — #filePath resolves on the building machine,
  /// so no username is ever committed).
  static let corePath: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let installed = home + "/bin/sheol-core"
    if FileManager.default.isExecutableFile(atPath: installed) { return installed }
    return URL(fileURLWithPath: #filePath)  // …/app/MachineSpirit/Sources/SheolService.swift
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("bin/sheol-core").path
  }()

  private static func run(_ arguments: [String]) async -> Data {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: corePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
          try process.run()
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          continuation.resume(returning: data)
        } catch {
          continuation.resume(returning: Data())
        }
      }
    }
  }

  static func list() async -> [Spirit] {
    let data = await run(["list", "--json"])
    return (try? JSONDecoder().decode([Spirit].self, from: data)) ?? []
  }

  /// Revive: a fresh body — a new iTerm window attaching. Reversible.
  static func revive(_ name: String) async {
    _ = await run(["revive", name])
  }

  /// Exile: kill a spirit already in sheol. Irreversible — callers guard it
  /// behind the ◆◆◇ ward.
  static func exile(_ name: String) async {
    _ = await run(["kill", name])
  }
}
