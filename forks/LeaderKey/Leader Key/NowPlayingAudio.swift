import Cocoa
import CoreAudio

struct NowPlayingProcess: Equatable {
  let object: AudioObjectID
  let pid: pid_t
}

// AppKit ownership resolution intentionally matches tools/ms/Sources/ms/Audio.swift.
// Unknown helpers stay separate; never guess that an arbitrary process is Safari.
func nowPlayingOwner(_ process: NSRunningApplication?, regular: [NSRunningApplication])
  -> NSRunningApplication?
{
  guard let process else { return nil }
  if process.activationPolicy == .regular { return process }
  if let path = process.bundleURL?.standardizedFileURL.path {
    let matches = regular.filter {
      guard let root = $0.bundleURL?.standardizedFileURL.path else { return false }
      return path.hasPrefix(root + "/")
    }
    if matches.count == 1 { return matches[0] }
  }
  if process.bundleIdentifier?.hasPrefix("com.apple.WebKit.") == true,
    let name = process.localizedName
  {
    let matches = regular.filter {
      guard let owner = $0.localizedName else { return false }
      return name == owner + " Graphics and Media" || name == owner + " Web Content"
        || name == owner + " Networking"
    }
    if matches.count == 1 { return matches[0] }
  }
  return process
}

private struct NowPlayingAudioError: Error {
  let status: OSStatus
}

private func audioCheck(_ status: OSStatus) throws {
  if status != noErr { throw NowPlayingAudioError(status: status) }
}

private func audioUInt(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws
  -> UInt32
{
  var address = AudioObjectPropertyAddress(
    mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  var value: UInt32 = 0
  var size = UInt32(MemoryLayout.size(ofValue: value))
  try audioCheck(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value))
  return value
}

func nowPlayingProcesses() throws -> [NowPlayingProcess] {
  dispatchPrecondition(condition: .notOnQueue(.main))
  guard #available(macOS 14.4, *) else { return [] }
  var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  try audioCheck(
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
  )
  guard size > 0 else { return [] }
  var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
  try objects.withUnsafeMutableBytes {
    try audioCheck(
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!))
  }
  return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { object in
    guard (try? audioUInt(object, kAudioProcessPropertyIsRunningOutput)) == 1,
      let raw = try? audioUInt(object, kAudioProcessPropertyPID)
    else { return nil }
    return NowPlayingProcess(object: object, pid: pid_t(bitPattern: raw))
  }
}

/// Shared atomic values outlive their IOProc; UI never owns a CoreAudio resource.
final class NowPlayingLevel {
  let pointer: OpaquePointer
  init() throws {
    guard let pointer = MSMeterCreate() else {
      throw NowPlayingAudioError(status: OSStatus(memFullErr))
    }
    self.pointer = pointer
  }
  var levels: MSLevels { MSMeterRead(pointer) }
  var hasReceivedAudio: Bool { MSMeterHasReceivedAudio(pointer) }
  deinit { MSMeterDestroy(pointer) }
}

protocol NowPlayingTapHandle: AnyObject {
  var level: NowPlayingLevel { get }
  func stop()
}

@available(macOS 14.4, *)
private final class NowPlayingTap: NowPlayingTapHandle {
  let level: NowPlayingLevel
  private var tap: AudioObjectID?
  private var device: AudioObjectID?
  private var ioProc: AudioDeviceIOProcID?

  init(process: NowPlayingProcess, isCancelled: () -> Bool) throws {
    func checkCancellation() throws {
      if isCancelled() { throw CancellationError() }
    }
    dispatchPrecondition(condition: .notOnQueue(.main))
    level = try NowPlayingLevel()
    do {
      let description = CATapDescription(stereoMixdownOfProcesses: [process.object])
      description.name = "MachineSpirit level meter"
      description.uuid = UUID()
      description.isPrivate = true
      description.muteBehavior = .unmuted
      var tapID: AudioObjectID = 0
      try checkCancellation()
      try audioCheck(AudioHardwareCreateProcessTap(description, &tapID))
      tap = tapID
      var format = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout.size(ofValue: format))
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      try checkCancellation()
      try audioCheck(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format))
      guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
        format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
        format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
        format.mFormatFlags & kAudioFormatFlagIsPacked != 0
      else {
        throw NowPlayingAudioError(status: kAudioDeviceUnsupportedFormatError)
      }
      let properties: [String: Any] = [
        kAudioAggregateDeviceNameKey: "MachineSpirit level meter",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [
          [
            kAudioSubTapUIDKey: description.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: true,
          ]
        ],
      ]
      var deviceID: AudioObjectID = 0
      try checkCancellation()
      try audioCheck(AudioHardwareCreateAggregateDevice(properties as CFDictionary, &deviceID))
      device = deviceID
      var callback: AudioDeviceIOProcID?
      try checkCancellation()
      try audioCheck(
        AudioDeviceCreateIOProcID(
          deviceID, MSMeterIOProc, UnsafeMutableRawPointer(level.pointer), &callback))
      ioProc = callback
      try checkCancellation()
      try audioCheck(AudioDeviceStart(deviceID, callback))
    } catch {
      stop()
      throw error
    }
  }

  func stop() {
    dispatchPrecondition(condition: .notOnQueue(.main))
    // Stop/destroy IO before releasing its atomic storage or the tap.
    if let device, let ioProc {
      AudioDeviceStop(device, ioProc)
      AudioDeviceDestroyIOProcID(device, ioProc)
    }
    ioProc = nil
    if let device { AudioHardwareDestroyAggregateDevice(device) }
    device = nil
    if let tap { AudioHardwareDestroyProcessTap(tap) }
    tap = nil
    assert(ioProc == nil && device == nil && tap == nil)
  }
  deinit { stop() }
}

/// All CoreAudio operations are serialized here. Main-thread close only cancels
/// work; the queue drains teardown without ever blocking AppKit menu tracking.
final class NowPlayingCapturePolicy {
  // Accessed only on the shared serial audio queue, across menu sessions.
  var unavailable = false
}

final class NowPlayingAudioSession {
  typealias TapFactory = (NowPlayingProcess) throws -> NowPlayingTapHandle
  struct Snapshot {
    var processes: [NowPlayingProcess]
    var levels: [AudioObjectID: NowPlayingLevel]
    var metersUnavailable: Bool
    var enumerationFailed: Bool = false
  }
  private let queue: DispatchQueue
  private let cancellationLock = NSLock()
  private var cancelled = false
  private var taps: [AudioObjectID: NowPlayingTapHandle]? = [:]
  private var identities: [AudioObjectID: pid_t] = [:]
  private var started: [AudioObjectID: TimeInterval] = [:]
  private let policy: NowPlayingCapturePolicy
  private var metersUnavailable: Bool {
    get { policy.unavailable }
    set { policy.unavailable = newValue }
  }
  private let enumerate: () throws -> [NowPlayingProcess]
  private let makeTap: TapFactory?

  init(
    queue: DispatchQueue, policy: NowPlayingCapturePolicy,
    enumerate: @escaping () throws -> [NowPlayingProcess] = nowPlayingProcesses,
    makeTap: TapFactory? = nil
  ) {
    self.queue = queue
    self.policy = policy
    self.enumerate = enumerate
    self.makeTap = makeTap
  }
  private func createTap(_ process: NowPlayingProcess) throws -> NowPlayingTapHandle {
    if let makeTap { return try makeTap(process) }
    if #available(macOS 14.4, *) {
      return try NowPlayingTap(process: process, isCancelled: { self.isCancelled })
    }
    throw NowPlayingAudioError(status: kAudioHardwareUnsupportedOperationError)
  }
  private var isCancelled: Bool {
    cancellationLock.lock()
    defer { cancellationLock.unlock() }
    return cancelled
  }
  func sample(_ receive: @escaping (Snapshot) -> Void) {
    queue.async { [self] in
      guard !isCancelled else { return }
      do {
        let processes = try enumerate()
        guard !isCancelled else { return }
        let wanted = Dictionary(
          processes.map { ($0.object, $0.pid) }, uniquingKeysWith: { first, _ in first })
        for id in Array(taps?.keys ?? [AudioObjectID: NowPlayingTapHandle]().keys)
        where identities[id] != wanted[id] {
          taps?.removeValue(forKey: id)?.stop()
          identities[id] = nil
          started[id] = nil
        }
        for process in processes where !metersUnavailable && !isCancelled {
          if let tap = taps?[process.object] {
            // Denied capture can appear as a successful tap with no IO.
            if !tap.level.hasReceivedAudio,
              ProcessInfo.processInfo.systemUptime - (started[process.object] ?? 0) > 3
            {
              metersUnavailable = true
            }
            continue
          }
          do {
            taps?[process.object] = try createTap(process)
            identities[process.object] = process.pid
            started[process.object] = ProcessInfo.processInfo.systemUptime
          } catch {
            if isCancelled { break }
            // One failure latches capture off. No one-second TCC retry loop.
            metersUnavailable = true
            NSLog("Now Playing meters unavailable: %@", String(describing: error))
          }
        }
        if metersUnavailable || isCancelled {
          for tap in taps?.values ?? [AudioObjectID: NowPlayingTapHandle]().values { tap.stop() }
          taps?.removeAll()
          identities.removeAll()
          started.removeAll()
        }
        guard !isCancelled else { return }
        receive(
          Snapshot(
            processes: processes, levels: taps?.mapValues(\.level) ?? [:],
            metersUnavailable: metersUnavailable))
      } catch {
        // A process list can race process exit. Remove stale rows and taps;
        // retry enumeration on the next tick, without latching TCC failure.
        for tap in taps?.values ?? [AudioObjectID: NowPlayingTapHandle]().values { tap.stop() }
        taps?.removeAll()
        identities.removeAll()
        started.removeAll()
        guard !isCancelled else { return }
        receive(
          Snapshot(
            processes: [], levels: [:], metersUnavailable: metersUnavailable,
            enumerationFailed: true))
      }
    }
  }
  func close(_ completion: (() -> Void)? = nil) {
    cancellationLock.lock()
    cancelled = true
    cancellationLock.unlock()
    queue.async { [self] in
      for tap in taps?.values ?? [AudioObjectID: NowPlayingTapHandle]().values { tap.stop() }
      taps = nil
      identities.removeAll()
      started.removeAll()
      assert(taps == nil)
      completion?()
    }
  }
}
