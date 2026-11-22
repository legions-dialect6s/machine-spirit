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
    if CommandLine.arguments.contains("--awake") || CommandLine.arguments.contains("--persistence") {
      let suiteName = "com.machinespirit.system-menu-smoke.\(UUID().uuidString)"
      let suite = UserDefaults(suiteName: suiteName)!
      defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
      suite.register(defaults: [KeepAwake.DefaultsKey.keepsDisplayOn: true])

      // Verify real IOPMAssertion persistence across relaunch (suspend -> fresh KeepAwake.restore()).
      let first = KeepAwake(defaults: suite)
      first.start(minutes: -1)
      let indefiniteAssertion = assertions()
      print("INDEFINITE: \(indefiniteAssertion)")
      precondition(indefiniteAssertion.contains("PreventUserIdleDisplaySleep"))
      first.keepsDisplayOn = false
      let systemOnlyAssertion = assertions()
      print("SYSTEM ONLY: \(systemOnlyAssertion)")
      precondition(systemOnlyAssertion.contains("PreventUserIdleSystemSleep"))
      first.suspend()
      precondition(assertions().isEmpty)

      let relaunched = KeepAwake(defaults: suite)
      precondition(relaunched.restore())
      let restoredAssertion = assertions()
      print("RESTORED INDEFINITE: \(restoredAssertion)")
      precondition(relaunched.minutes == -1 && restoredAssertion.contains("PreventUserIdleSystemSleep"))

      relaunched.keepsDisplayOn = true
      relaunched.start(minutes: 15)
      let originalDeadline = relaunched.deadline!
      relaunched.suspend()
      precondition(assertions().isEmpty)

      let relaunchedTimed = KeepAwake(defaults: suite)
      precondition(relaunchedTimed.restore())
      let restoredTimedAssertion = assertions()
      print("RESTORED TIMED: \(restoredTimedAssertion)")
      precondition(
        relaunchedTimed.minutes == 15
          && abs((relaunchedTimed.deadline?.timeIntervalSince1970 ?? 0) - originalDeadline.timeIntervalSince1970) < 0.01
          && restoredTimedAssertion.contains("PreventUserIdleDisplaySleep"))

      relaunchedTimed.stop()
      precondition(assertions().isEmpty)
      let afterStop = KeepAwake(defaults: suite)
      precondition(!afterStop.restore() && assertions().isEmpty)
      print("OFF: explicit stop cleared persisted session and released assertion")

      if CommandLine.arguments.contains("--awake") {
        let timed = KeepAwake(defaults: suite)
        timed.start(minutes: 1)
        print("TIMED: \(assertions())")
        let deadline = Date().addingTimeInterval(61)
        while Date() < deadline {
          RunLoop.main.run(until: Date().addingTimeInterval(0.5))
          timed.checkExpiry()
        }
        precondition(timed.minutes == 0 && assertions().isEmpty)
        let afterExpiry = KeepAwake(defaults: suite)
        precondition(!afterExpiry.restore())
        print("EXPIRY: assertion released and persisted session cleared after 60 seconds")
      }
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
