import Cocoa
import IOKit.pwr_mgt
import os.log

/// Owns one assertion and one deadline. The status bar heartbeat checks expiry.
final class KeepAwake {
  private var assertion: IOPMAssertionID = 0
  private(set) var minutes: Int = 0  // -1 = indefinitely, 0 = off
  private(set) var deadline: Date?
  var onChange: (() -> Void)?

  var keepsDisplayOn: Bool {
    get { UserDefaults.standard.bool(forKey: "msKeepAwakeDisplay") }
    set {
      UserDefaults.standard.set(newValue, forKey: "msKeepAwakeDisplay")
      if minutes != 0 { replaceAssertion() }
      onChange?()
    }
  }

  func start(minutes: Int) {
    stop()
    guard minutes != 0 else { return }
    self.minutes = minutes
    guard replaceAssertion() else { return }
    if minutes > 0 {
      deadline = Date().addingTimeInterval(Double(minutes) * 60)

    }
    onChange?()
  }

  @discardableResult
  private func replaceAssertion() -> Bool {
    releaseAssertion()
    let type =
      keepsDisplayOn
      ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
    let result = IOPMAssertionCreateWithName(
      type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
      "machine-spirit keep-awake" as CFString, &assertion)
    guard result == kIOReturnSuccess else {
      os_log("System menu: keep-awake assertion failed: %d", result)
      assertion = 0
      stop()
      return false
    }
    return true
  }

  func checkExpiry() {
    if let deadline, deadline <= Date() { stop() }
  }

  private func releaseAssertion() {
    if assertion != 0 { IOPMAssertionRelease(assertion) }
    assertion = 0
  }

  func stop() {
    releaseAssertion()
    minutes = 0
    deadline = nil
    onChange?()
  }

  deinit {
    releaseAssertion()
  }
}
