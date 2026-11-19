import Cocoa

@main struct BrightnessSmoke {
  static func main() {
    let hardware = DisplayHardware()
    let screens = NSScreen.screens
    let ids = screens.map {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
    }
    let services = hardware.services(for: ids.filter { CGDisplayIsBuiltin($0) == 0 })
    let originals = ids.map { id -> Double? in
      if CGDisplayIsBuiltin(id) != 0 { return hardware.readBuiltIn(id) }
      return services[id].flatMap { hardware.readDDC($0) }.map { Double($0.current) }
    }
    UserDefaults.standard.register(defaults: [
      "msBrightnessSync": true, "msBrightnessKeysEnabled": false,
    ])
    let controller = BrightnessController()
    controller.start()
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    controller.setAll(12.5)
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    var passed = true
    for display in controller.displays {
      var r = [Float](repeating: 0, count: 4096)
      var g = r
      var b = r
      var count: UInt32 = 0
      let result = CGGetDisplayTransferByTable(display.id, 4096, &r, &g, &b, &count)
      let maximum = count > 0 ? r[Int(count) - 1] : 0
      print(
        "GAMMA \(display.screen.localizedName): result=\(result.rawValue) max=\(maximum), expected≈0.575; hardware=\(display.available)"
      )
      passed = passed && result == .success && abs(maximum - 0.575) < 0.02
    }
    controller.setAll(50)
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    for display in controller.displays {
      let actual =
        display.builtIn
        ? hardware.readBuiltIn(display.id)
        : services[display.id].flatMap { hardware.readDDC($0) }.map { Double($0.current) }
      print(
        "SYNC 50 \(display.screen.localizedName): hardware=\(String(describing: actual)), expected≈33"
      )
      passed = passed && actual.map { abs($0 - 33.33) < 1 } == true
    }
    controller.stop()
    for (index, id) in ids.enumerated() {
      if let value = originals[index] {
        if CGDisplayIsBuiltin(id) != 0 {
          _ = hardware.writeBuiltIn(id, percent: value)
        } else if let service = services[id] {
          _ = hardware.writeDDC(service, value: UInt16(value))
        }
      }
    }
    print("RESTORED original hardware and ColorSync; passed=\(passed)")
    if !passed { exit(1) }
  }
}
