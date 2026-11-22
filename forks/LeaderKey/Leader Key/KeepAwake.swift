import Cocoa
import IOKit.pwr_mgt
import os.log

/// Owns one assertion and one deadline. Active sessions persist across relaunch;
/// the status bar heartbeat checks expiry.
final class KeepAwake {
  enum DefaultsKey {
    static let keepsDisplayOn = "msKeepAwakeDisplay"
    static let sessionMinutes = "msKeepAwakeSessionMinutes"
    static let sessionDeadline = "msKeepAwakeSessionDeadline"
  }

  typealias CreateAssertion = (_ type: String, _ name: String) -> IOPMAssertionID?
  typealias ReleaseAssertion = (_ id: IOPMAssertionID) -> Void

  private let defaults: UserDefaults
  private let now: () -> Date
  private let createAssertion: CreateAssertion
  private let releaseAssertionBlock: ReleaseAssertion
  private var assertion: IOPMAssertionID = 0
  private(set) var minutes: Int = 0  // -1 = indefinitely, 0 = off
  private(set) var deadline: Date?
  var isActive: Bool { minutes != 0 }
  var onChange: (() -> Void)?

  init(
    defaults: UserDefaults = .standard,
    now: @escaping () -> Date = Date.init,
    createAssertion: @escaping CreateAssertion = KeepAwake.systemCreateAssertion,
    releaseAssertion: @escaping ReleaseAssertion = KeepAwake.systemReleaseAssertion
  ) {
    self.defaults = defaults
    self.now = now
    self.createAssertion = createAssertion
    self.releaseAssertionBlock = releaseAssertion
  }

  static func systemCreateAssertion(type: String, name: String) -> IOPMAssertionID? {
    var id: IOPMAssertionID = 0
    let result = IOPMAssertionCreateWithName(
      type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
    guard result == kIOReturnSuccess else {
      os_log("System menu: keep-awake assertion failed: %d", result)
      return nil
    }
    return id
  }

  static func systemReleaseAssertion(_ id: IOPMAssertionID) {
    IOPMAssertionRelease(id)
  }

  var keepsDisplayOn: Bool {
    get { defaults.object(forKey: DefaultsKey.keepsDisplayOn) as? Bool ?? true }
    set {
      defaults.set(newValue, forKey: DefaultsKey.keepsDisplayOn)
      if minutes != 0, !replaceAssertion() {
        clearInMemory(clearPersisted: true)
      }
      onChange?()
    }
  }

  func start(minutes: Int) {
    guard minutes != 0 else {
      stop()
      return
    }
    guard minutes == -1 || minutes > 0 else {
      stop()
      return
    }
    let nextDeadline = minutes > 0 ? now().addingTimeInterval(Double(minutes) * 60) : nil
    self.minutes = minutes
    self.deadline = nextDeadline
    guard replaceAssertion() else {
      clearInMemory(clearPersisted: true)
      onChange?()
      return
    }
    persistSession()
    onChange?()
  }

  /// Restore an active session saved before relaunch or crash. Expired or invalid
  /// persisted sessions are cleared without creating an assertion.
  @discardableResult
  func restore() -> Bool {
    guard defaults.object(forKey: DefaultsKey.sessionMinutes) != nil else { return false }
    let savedMinutes = defaults.integer(forKey: DefaultsKey.sessionMinutes)
    if savedMinutes == -1 {
      minutes = -1
      deadline = nil
      guard replaceAssertion() else {
        clearInMemory(clearPersisted: false)
        return false
      }
      defaults.removeObject(forKey: DefaultsKey.sessionDeadline)
      onChange?()
      return true
    }
    guard savedMinutes > 0,
      let deadlineEpoch = defaults.object(forKey: DefaultsKey.sessionDeadline) as? Double,
      deadlineEpoch.isFinite
    else {
      clearPersistedSession()
      return false
    }
    let savedDeadline = Date(timeIntervalSince1970: deadlineEpoch)
    guard savedDeadline > now() else {
      clearPersistedSession()
      return false
    }
    minutes = savedMinutes
    deadline = savedDeadline
    guard replaceAssertion() else {
      clearInMemory(clearPersisted: false)
      return false
    }
    onChange?()
    return true
  }

  @discardableResult
  private func replaceAssertion() -> Bool {
    releaseAssertion()
    let type =
      keepsDisplayOn
      ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
    guard let id = createAssertion(type, "machine-spirit keep-awake") else {
      assertion = 0
      return false
    }
    assertion = id
    return true
  }

  func remainingMinutes(at referenceDate: Date? = nil) -> Int? {
    guard let deadline else { return nil }
    return max(0, Int(ceil(deadline.timeIntervalSince(referenceDate ?? now()) / 60)))
  }

  func statusSummary(at referenceDate: Date? = nil) -> String {
    if let remaining = remainingMinutes(at: referenceDate) {
      return remaining >= 60
        ? "\(remaining / 60)h" + (remaining % 60 == 0 ? "" : " \(remaining % 60)m") + " left"
        : "\(remaining)m left"
    }
    return isActive ? "indefinitely" : "off"
  }

  func checkExpiry() {
    if let deadline, deadline <= now() { stop() }
  }

  private func persistSession() {
    defaults.set(minutes, forKey: DefaultsKey.sessionMinutes)
    if let deadline {
      defaults.set(deadline.timeIntervalSince1970, forKey: DefaultsKey.sessionDeadline)
    } else {
      defaults.removeObject(forKey: DefaultsKey.sessionDeadline)
    }
  }

  private func clearPersistedSession() {
    defaults.removeObject(forKey: DefaultsKey.sessionMinutes)
    defaults.removeObject(forKey: DefaultsKey.sessionDeadline)
  }

  private func releaseAssertion() {
    if assertion != 0 { releaseAssertionBlock(assertion) }
    assertion = 0
  }

  private func clearInMemory(clearPersisted: Bool) {
    releaseAssertion()
    minutes = 0
    deadline = nil
    if clearPersisted { clearPersistedSession() }
  }

  /// Explicitly end the session (user selected Off or timed session expired).
  func stop() {
    clearInMemory(clearPersisted: true)
    onChange?()
  }

  /// Release the assertion for app termination without erasing the persisted session.
  func suspend() {
    clearInMemory(clearPersisted: false)
  }

  deinit {
    releaseAssertion()
  }
}
