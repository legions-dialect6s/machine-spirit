import Foundation
import Darwin

struct Failure: Error, LocalizedError {
    let message: String
    let exitCode: Int32
    init(_ message: String, exitCode: Int32 = 1) { self.message = message; self.exitCode = exitCode }
    var errorDescription: String? { message }
}

func oneLine(_ text: String) -> String {
    text.components(separatedBy: .newlines).joined(separator: " ")
}

func jsonString(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    return String(decoding: data, as: UTF8.self)
}

struct Output {
    let json: Any
    let text: String
    var imagePath: String? = nil
}

/// Unknown/duplicate flags are errors. `--` allows a positional beginning with '-'.
struct Arguments {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ args: [String], values: Set<String> = [], switches: Set<String> = []) throws {
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--" { positionals += args.dropFirst(i + 1); break }
            if values.contains(arg) {
                guard options[arg] == nil, i + 1 < args.count else {
                    throw Failure("missing value or duplicate option: \(arg)")
                }
                i += 1
                options[arg] = args[i]
            } else if switches.contains(arg) {
                guard flags.insert(arg).inserted else { throw Failure("duplicate option: \(arg)") }
            } else if arg.hasPrefix("-") {
                throw Failure("unknown option: \(arg)")
            } else { positionals.append(arg) }
            i += 1
        }
    }

    func count(_ count: Int) throws {
        guard positionals.count == count else { throw Failure("expected \(count) positional argument(s); see ms --help") }
    }
}

func homeURL(_ path: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
}

func expandedPath(_ path: String) -> String { (path as NSString).expandingTildeInPath }

func positiveID(_ value: String) throws -> UInt32 {
    guard let id = UInt32(value), id > 0 else { throw Failure("invalid ID: \(value)") }
    return id
}

/// Drain a single combined pipe while running, avoiding stdout/stderr pipe deadlocks.
/// Only the `run` command uses a shell; every other subprocess uses literal argv.
func process(_ executable: String, _ arguments: [String], detached: Bool = false) throws -> (String, Int32) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    task.standardInput = FileHandle.nullDevice
    if detached {
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        return ("", task.processIdentifier)
    }
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    try task.run()
    var data = Data()
    while true {
        let chunk = pipe.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        guard data.count + chunk.count <= 16 * 1024 * 1024 else {
            task.terminate()
            throw Failure("subprocess output exceeded 16 MiB")
        }
        data.append(chunk)
    }
    task.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard task.terminationStatus == 0 else {
        throw Failure("\(URL(fileURLWithPath: executable).lastPathComponent) exited \(task.terminationStatus): \(oneLine(output))")
    }
    return (output, task.processIdentifier)
}
