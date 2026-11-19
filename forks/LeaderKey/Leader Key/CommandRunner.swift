import Cocoa
import os.log

class CommandRunner {
  struct Result {
    let status: Int32
    let output: String
  }

  // Preserve group command ordering without blocking AppKit or animation completion.
  private static let queue = DispatchQueue(label: "com.machinespirit.commands", qos: .userInitiated)

  static func run(_ command: String, completion: ((Result) -> Void)? = nil) {
    queue.async {
      let task = Process()
      let pipe = Pipe()
      task.standardOutput = pipe
      task.standardError = pipe
      task.standardInput = FileHandle.nullDevice
      let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
      task.executableURL = URL(fileURLWithPath: shell)
      task.arguments = ["-c", command]
      var environment = ProcessInfo.processInfo.environment
      environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
      environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
      task.environment = environment
      let result: Result
      do {
        try task.run()
        // Drain while the process runs, with bounded diagnostic storage. Waiting
        // before draining can deadlock as soon as a pipe buffer fills.
        var output = Data()
        while true {
          let chunk = pipe.fileHandleForReading.availableData
          if chunk.isEmpty { break }
          if output.count < 65_536 { output.append(chunk.prefix(65_536 - output.count)) }
        }
        task.waitUntilExit()
        result = Result(
          status: task.terminationStatus, output: String(decoding: output, as: UTF8.self))
      } catch {
        result = Result(status: -1, output: error.localizedDescription)
      }
      os_log("Leader command completed: status=%d", result.status)
      DispatchQueue.main.async {
        if let completion {
          completion(result)
          return
        }
        guard result.status != 0 else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText =
          result.status == -1
          ? "Failed to run command" : "Command failed with exit code \(result.status)"
        alert.informativeText = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.runModal()
      }
    }
  }
}
