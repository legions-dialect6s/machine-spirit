import Foundation

/// Why a write was refused. Every case is loud on purpose — the writer
/// never "does its best"; it either proves the write safe or leaves the
/// target byte-for-byte untouched.
public enum WriteError: Error, CustomStringConvertible {
  /// The CURRENT target file does not round-trip through the model — the
  /// model would corrupt something it doesn't fully understand. The diff
  /// paths say where the round trip diverged.
  case gateRefused(mismatches: [String])
  /// The target file doesn't exist. The live config always does; creating
  /// files is deliberately outside this ritual's power.
  case targetMissing(String)
  /// The written temp file did not re-import to the intended model
  /// (a corrupted serialize, a filesystem lie). The target was not touched.
  case validationFailed(mismatches: [String])
  /// Plain I/O failure, annotated with the step that failed.
  case io(String)

  public var description: String {
    switch self {
    case .gateRefused(let mismatches):
      return "gate red — the current config does not round-trip; refusing to write. Diverges at: "
        + mismatches.joined(separator: ", ")
    case .targetMissing(let path):
      return "target does not exist: \(path)"
    case .validationFailed(let mismatches):
      return "written artifact failed re-import validation; target untouched. Diverges at: "
        + mismatches.joined(separator: ", ")
    case .io(let step):
      return "I/O failure during \(step)"
    }
  }
}

/// What a successful write did: where the pre-write backup lives, and a
/// node-level summary of the change (`+ root/m`, `− root/x`, `~ root/t`).
public struct WriteReport: Equatable, Sendable {
  public let backupPath: String
  public let summary: [String]
}

/// The write ritual, in order, refusing loudly at every gate:
///
/// 1. **Gate precondition** — round-trip the CURRENT target through the
///    model; any mismatch refuses the write (a red gate means the model
///    would corrupt something it doesn't fully understand).
/// 2. **Backup** — copy the target to the backup directory
///    (`config-<ISO-timestamp>.json`), created if needed.
/// 3. **Temp-write + validate** — serialize to a temp file BESIDE the
///    target, re-import it, and verify canonical equality with the
///    intended model. The artifact is proven before it exists at the
///    real path.
/// 4. **Atomic swap** — `rename(2)` over the target.
///
/// The target path is a parameter: tests and first proofs run against
/// temp files; the live config is only ever a deliberate caller choice.
public struct ConfigWriter {
  public let probe: AvailabilityProbe
  /// Injectable so tests can prove the validator catches a lying
  /// serializer. Defaults to the real one.
  public let serialize: @Sendable (Node) throws -> Data
  public let backupDirectory: URL

  /// The real backup home: `~/.local/state/machine-spirit/config-backups`
  /// — never inside the public repo.
  public static var defaultBackupDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/state/machine-spirit/config-backups", isDirectory: true)
  }

  public init(
    probe: AvailabilityProbe = FileSystemProbe(),
    serialize: @escaping @Sendable (Node) throws -> Data = { try LeaderKeySerializer.data(from: $0) },
    backupDirectory: URL = ConfigWriter.defaultBackupDirectory
  ) {
    self.probe = probe
    self.serialize = serialize
    self.backupDirectory = backupDirectory
  }

  @discardableResult
  public func write(_ model: Node, to target: URL) throws -> WriteReport {
    let fm = FileManager.default

    // 1. Gate precondition.
    guard fm.fileExists(atPath: target.path) else {
      throw WriteError.targetMissing(target.path)
    }
    guard let currentData = try? Data(contentsOf: target) else {
      throw WriteError.io("reading current target")
    }
    let importer = LeaderKeyImporter(probe: probe)
    guard let currentModel = try? importer.importConfig(from: currentData),
      let currentRaw = try? JSONDecoder().decode(JSONValue.self, from: currentData)
    else {
      throw WriteError.gateRefused(mismatches: ["<target failed to parse or import>"])
    }
    let roundTripped = LeaderKeySerializer.jsonValue(from: currentModel)
    let gateMismatches = JSONValue.mismatchPaths(currentRaw, roundTripped)
    guard gateMismatches.isEmpty else {
      throw WriteError.gateRefused(mismatches: gateMismatches)
    }

    // 2. Backup.
    do {
      try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
    } catch {
      throw WriteError.io("creating backup directory")
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let backupURL = backupDirectory.appendingPathComponent("config-\(stamp).json")
    do {
      try fm.copyItem(at: target, to: backupURL)
    } catch {
      throw WriteError.io("backing up target")
    }

    // 3. Temp-write + validate.
    let tempURL = target.deletingLastPathComponent()
      .appendingPathComponent(".\(target.lastPathComponent).ms-tmp-\(UUID().uuidString)")
    let bytes: Data
    do {
      bytes = try serialize(model)
      try bytes.write(to: tempURL)
    } catch {
      try? fm.removeItem(at: tempURL)
      throw WriteError.io("writing temp file")
    }
    let intended = LeaderKeySerializer.jsonValue(from: model)
    guard let reimported = try? importer.importConfig(at: tempURL) else {
      try? fm.removeItem(at: tempURL)
      throw WriteError.validationFailed(mismatches: ["<temp file failed to re-import>"])
    }
    let validationMismatches = JSONValue.mismatchPaths(
      intended, LeaderKeySerializer.jsonValue(from: reimported))
    guard validationMismatches.isEmpty else {
      try? fm.removeItem(at: tempURL)
      throw WriteError.validationFailed(mismatches: validationMismatches)
    }

    // 4. Atomic swap.
    guard rename(tempURL.path, target.path) == 0 else {
      try? fm.removeItem(at: tempURL)
      throw WriteError.io("atomic rename over target")
    }

    return WriteReport(
      backupPath: backupURL.path,
      summary: Self.changeSummary(from: currentModel, to: model))
  }

  // MARK: - Node-level change summary

  /// `+ id` added, `− id` removed, `~ id` changed in place. Ids are
  /// structural paths, same as everywhere else in the kit.
  static func changeSummary(from old: Node, to new: Node) -> [String] {
    var before: [String: String] = [:]
    var after: [String: String] = [:]
    flatten(old, into: &before)
    flatten(new, into: &after)
    var lines: [String] = []
    for (id, fingerprint) in after where before[id] != fingerprint {
      lines.append(before[id] == nil ? "+ \(id)" : "~ \(id)")
    }
    for id in before.keys where after[id] == nil {
      lines.append("− \(id)")
    }
    return lines.sorted { $0.dropFirst(2) < $1.dropFirst(2) }
  }

  private static func flatten(_ node: Node, into map: inout [String: String]) {
    // The fingerprint is the node's own content, children excluded —
    // a child edit must not mark every ancestor as changed.
    let action = node.action.map { "\($0.typeString):\($0.value)" } ?? "group"
    map[node.id] = "\(node.key ?? "")|\(node.label ?? "")|\(action)|\(node.extras.count)"
    for child in node.children { flatten(child, into: &map) }
  }
}

extension JSONValue {
  /// Paths where two JSON trees diverge (capped — this feeds error
  /// messages, not a diff tool). Arrays compare positionally; objects by
  /// key union.
  public static func mismatchPaths(
    _ a: JSONValue, _ b: JSONValue, at path: String = "$", limit: Int = 10
  ) -> [String] {
    var found: [String] = []
    collectMismatches(a, b, at: path, into: &found, limit: limit)
    return found
  }

  private static func collectMismatches(
    _ a: JSONValue, _ b: JSONValue, at path: String, into found: inout [String], limit: Int
  ) {
    guard found.count < limit else { return }
    switch (a, b) {
    case let (.object(x), .object(y)):
      for key in Set(x.keys).union(y.keys).sorted() {
        switch (x[key], y[key]) {
        case let (va?, vb?):
          collectMismatches(va, vb, at: "\(path).\(key)", into: &found, limit: limit)
        default:
          found.append("\(path).\(key)")
          if found.count >= limit { return }
        }
      }
    case let (.array(x), .array(y)):
      if x.count != y.count {
        found.append("\(path).count(\(x.count)≠\(y.count))")
        return
      }
      for (index, pair) in zip(x, y).enumerated() {
        collectMismatches(pair.0, pair.1, at: "\(path)[\(index)]", into: &found, limit: limit)
      }
    default:
      if a != b { found.append(path) }
    }
  }
}
