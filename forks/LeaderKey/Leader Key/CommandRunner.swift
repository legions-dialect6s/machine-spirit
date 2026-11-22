import ApplicationServices
import Cocoa
import os.lock
import os.log

class CommandRunner {
  struct Result {
    let status: Int32
    let output: String
  }

  // Preserve group command ordering without blocking AppKit or animation completion.
  private static let queue = DispatchQueue(label: "com.machinespirit.commands", qos: .userInitiated)

  static func run(_ command: String, on worker: DispatchQueue? = nil, completion: ((Result) -> Void)? = nil) {
    (worker ?? queue).async {
      let result: Result
      if let url = rectangleActionURL(for: command), activeWindowIsWindowed() {
        result = openRectangle(url)
      } else {
        result = runShell(command)
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

  static func rectangleActionURL(for command: String) -> URL? {
    let prefix = "~/bin/ms win rectangle \"rectangle://execute-action?name="
    guard command.hasPrefix(prefix), command.hasSuffix("\"") else { return nil }
    let name = command.dropFirst(prefix.count).dropLast()
    guard !name.isEmpty,
          name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return nil }
    return URL(string: "rectangle://execute-action?name=\(name)")
  }

  private static func activeWindowIsWindowed() -> Bool {
    guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return false }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 0.05)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
          let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
    let window = unsafeDowncast(focused, to: AXUIElement.self)
    AXUIElementSetMessagingTimeout(window, 0.05)
    var fullscreen: CFTypeRef?
    return AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreen) == .success &&
      fullscreen as? Bool == false
  }

  private static func openRectangle(_ url: URL) -> Result {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    let finished = DispatchSemaphore(value: 0)
    let outcome = OSAllocatedUnfairLock<Result?>(initialState: nil)
    // Keep delivery ordered on the command worker. AppKit's main queue stays free.
    NSWorkspace.shared.open(url, configuration: configuration) { _, error in
      let result = Result(status: error == nil ? 0 : 1, output: error?.localizedDescription ?? "")
      outcome.withLock { $0 = result }
      finished.signal()
    }
    guard finished.wait(timeout: .now() + 2) == .success else {
      return Result(status: 1, output: "Timed out dispatching Rectangle action")
    }
    return outcome.withLock { $0 } ?? Result(status: 1, output: "Rectangle action did not report a result")
  }

  private static func runShell(_ command: String) -> Result {
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
      return Result(
        status: task.terminationStatus, output: String(decoding: output, as: UTF8.self))
    } catch {
      return Result(status: -1, output: error.localizedDescription)
    }
  }
}
