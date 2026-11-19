// Compile with KeepAwake.swift and DisplayHardware.swift; runs outside the app.
import Cocoa

@main
struct SystemMenuSmoke {
  static func assertions() -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    task.arguments = ["-g", "assertions"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try! task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n")
      .filter {
        $0.contains("machine-spirit keep-awake")
          && $0.contains("pid \(ProcessInfo.processInfo.processIdentifier)(")
      }.joined(separator: "\n")
  }

  static func main() {
    if CommandLine.arguments.contains("--awake") {
      UserDefaults.standard.register(defaults: ["msKeepAwakeDisplay": true])
      let awake = KeepAwake()
      awake.start(minutes: -1)
      print("INDEFINITE: \(assertions())")
      precondition(!assertions().isEmpty)
      awake.keepsDisplayOn = false
      print("SYSTEM ONLY: \(assertions())")
      awake.stop()
      precondition(assertions().isEmpty)
      print("OFF: no machine-spirit assertion")
      awake.start(minutes: 1)
      print("TIMED: \(assertions())")
      let deadline = Date().addingTimeInterval(61)
      while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        awake.checkExpiry()
      }
      precondition(awake.minutes == 0 && assertions().isEmpty)
      print("EXPIRY: assertion released after 60 seconds")
    } else {
      let screens = NSScreen.screens.map { screen in
        (
          (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber)
            .uint32Value,
          screen.localizedName
        )
      }
      let queue = DispatchQueue(label: "system-menu-smoke.hardware")
      queue.sync {
        let hardware = DisplayHardware()
        let services = hardware.services(
          for: screens.filter { CGDisplayIsBuiltin($0.0) == 0 }.map { $0.0 })
        for (id, name) in screens {
          if CGDisplayIsBuiltin(id) != 0 {
            print(
              "BUILT-IN \(name) id=\(id) brightness=\(String(describing: hardware.readBuiltIn(id)))"
            )
          } else if let service = services[id], let value = hardware.readDDC(service) {
            print("DDC \(name) id=\(id) current=\(value.current) max=\(value.maximum)")
            if CommandLine.arguments.contains("--round-trip") {
              let test = value.current < value.maximum ? value.current + 1 : value.current - 1
              let written = hardware.writeDDC(service, value: test)
              usleep(100_000)
              let changed = hardware.readDDC(service)
              let restored = hardware.writeDDC(service, value: value.current)
              usleep(100_000)
              let after = hardware.readDDC(service)
              print(
                "ROUNDTRIP \(name): original=\(value.current) requested=\(test) read=\(String(describing: changed?.current)) restored=\(String(describing: after?.current))"
              )
              precondition(
                written && restored && changed?.current == test && after?.current == value.current)
            }
            if CommandLine.arguments.contains("--write-same") {
              precondition(hardware.writeDDC(service, value: value.current))
              let after = hardware.readDDC(service)
              precondition(after?.current == value.current)
              print("WRITE/READ restored same brightness: \(after!.current)")
            }
          } else {
            print("NO DDC \(name) id=\(id) matched=\(services[id] != nil)")
          }
        }
      }
    }
  }
}
