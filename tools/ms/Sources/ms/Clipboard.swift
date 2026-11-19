import Foundation

struct ClipboardArchive: Decodable {
    let version: Int
    let entries: [ClipboardEntry]
}

struct ClipboardEntry: Decodable {
    let id: UUID
    let kind: String
    let text: String?
    let fileURLs: [String]?
    let imageName: String?
    let pinned: Bool
    let date: Date
}

var clipboardAllowed: Bool { ProcessInfo.processInfo.environment["MS_ALLOW_CLIPBOARD"] == "1" }

func clipboard(_ args: [String]) throws -> Output {
    guard clipboardAllowed else { throw Failure("clipboard access disabled") }
    let parsed = try Arguments(args, values: ["-n"])
    let verb = parsed.positionals.first ?? "list"
    let directory = homeURL("Library/Application Support/MachineSpirit/clipboard")
    let archive: ClipboardArchive
    do { archive = try JSONDecoder().decode(ClipboardArchive.self, from: Data(contentsOf: directory.appendingPathComponent("index.json"))) }
    catch { throw Failure("cannot read clipboard index: \(error.localizedDescription)") }
    guard archive.version == 1 else { throw Failure("unsupported clipboard archive version \(archive.version)") }
    if verb == "list" {
        guard parsed.positionals.count <= 1 else { throw Failure("usage: ms clipboard list [-n 20]") }
        guard let limit = Int(parsed.options["-n"] ?? "20"), (1...1000).contains(limit) else { throw Failure("-n must be between 1 and 1000") }
        let rows: [[String: Any]] = archive.entries.prefix(limit).enumerated().map { index, entry in
            let preview = entry.kind == "image" ? "Image" : entry.text ?? entry.fileURLs?.joined(separator: ", ") ?? ""
            return ["index": index, "id": entry.id.uuidString, "kind": entry.kind, "pinned": entry.pinned,
                    "date": entry.date.ISO8601Format(), "preview": String(oneLine(preview).prefix(160))]
        }
        return Output(json: ["entries": rows, "total": archive.entries.count],
                      text: rows.map { "\($0["index"]!) | \($0["kind"]!) | \($0["preview"]!)" }.joined(separator: "\n"))
    }
    guard verb == "get", parsed.positionals.count == 2, parsed.options.isEmpty,
          let index = Int(parsed.positionals[1]), archive.entries.indices.contains(index) else {
        throw Failure("usage: ms clipboard get INDEX (zero-based index from list)")
    }
    let entry = archive.entries[index]
    var row: [String: Any] = ["index": index, "id": entry.id.uuidString, "kind": entry.kind,
                              "pinned": entry.pinned, "date": entry.date.ISO8601Format()]
    row["text"] = entry.text as Any? ?? NSNull()
    row["fileURLs"] = entry.fileURLs as Any? ?? NSNull()
    var text = entry.text ?? entry.fileURLs?.joined(separator: "\n") ?? ""
    if entry.kind == "image" {
        // The archive is data, not authorization to return arbitrary file paths.
        guard entry.imageName == entry.id.uuidString + ".png" else { throw Failure("invalid clipboard image filename") }
        let file = directory.appendingPathComponent(entry.imageName!)
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw Failure("clipboard image is not a regular file") }
        row["imagePath"] = file.path
        text = file.path
    }
    return Output(json: row, text: text)
}
