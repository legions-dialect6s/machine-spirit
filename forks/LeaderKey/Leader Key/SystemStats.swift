import Cocoa
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration

/// One owner, one closed-menu heartbeat. No subprocesses on this sampling path.
final class CPUUsageReader {
  private let host = mach_host_self()
  private var previous: processor_info_array_t?
  private var previousCount: mach_msg_type_number_t = 0
  private(set) var cpuPercent = 0
  private(set) var hasDelta = false
  private(set) var cores: [Double] = []

  func sample(includeCores: Bool = false) {
    var count: mach_msg_type_number_t = 0
    var cpus: natural_t = 0
    var info: processor_info_array_t?
    guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
      let info
    else { return }
    if includeCores && cores.count != Int(cpus) { cores = Array(repeating: 0, count: Int(cpus)) }
    var total: UInt64 = 0
    var busy: UInt64 = 0
    if let previous, previousCount == count {
      for core in 0..<Int(cpus) {
        var coreTotal: UInt64 = 0
        var coreBusy: UInt64 = 0
        for state in 0..<Int(CPU_STATE_MAX) {
          let index = core * Int(CPU_STATE_MAX) + state
          let delta = UInt64(UInt32(bitPattern: info[index]) &- UInt32(bitPattern: previous[index]))
          coreTotal += delta
          if state != Int(CPU_STATE_IDLE) { coreBusy += delta }
        }
        if includeCores {
          cores[core] = coreTotal == 0 ? 0 : Double(coreBusy) * 100 / Double(coreTotal)
        }
        total += coreTotal
        busy += coreBusy
      }
      hasDelta = total > 0
      if total > 0 { cpuPercent = Int((Double(busy) * 100 / Double(total)).rounded()) }
    }
    if let previous {
      vm_deallocate(
        mach_task_self_, vm_address_t(bitPattern: previous), vm_size_t(previousCount) * 4)
    }
    previous = info
    previousCount = count
  }

  deinit {
    if let previous {
      vm_deallocate(
        mach_task_self_, vm_address_t(bitPattern: previous), vm_size_t(previousCount) * 4)
    }
    mach_port_deallocate(mach_task_self_, host)
  }
}

/// Native API selection and HID protocol adapted from exelban/Stats (MIT).
/// See Stats-LICENSE.txt; no Stats binary, helper, or framework is required.
final class SystemStats {
  struct Row {
    let name: String
    let summary: String
    let details: [String]
  }
  static let names = ["CPU", "GPU", "Memory", "Network ↓/↑", "Disk", "Battery", "Temperatures"]
  private let cpu = CPUUsageReader()  // Main-thread, 2s bar sample only.
  private let queue = DispatchQueue(label: "com.machinespirit.stats", qos: .utility)
  private var timer: Timer?
  private var generation = 0
  private var inFlight = false
  private(set) var isOpen = false
  private(set) var detailedSamples = 0
  var onUpdate: (([Row]) -> Void)?
  var cpuPercent: Int { cpu.cpuPercent }
  func sampleCPU() { cpu.sample() }

  // Worker-confined readers. Allocate/reset only on open, retain no sensor clients when closed.
  private var details: DetailReader?

  func open() {
    guard !isOpen else { return }
    isOpen = true
    generation += 1
    let current = generation
    queue.async { self.details = DetailReader() }
    refresh(generation: current)
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      self?.refresh(generation: current)
    }
    timer.tolerance = 0.2
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func close() {
    isOpen = false
    generation += 1
    timer?.invalidate()
    timer = nil
    queue.async { self.details = nil }
  }

  private func refresh(generation current: Int) {
    guard isOpen, !inFlight, generation == current else { return }
    inFlight = true
    queue.async {
      let rows = self.details?.sample() ?? []
      DispatchQueue.main.async {
        self.inFlight = false
        guard self.isOpen, self.generation == current else { return }
        self.detailedSamples += 1
        self.onUpdate?(rows)
      }
    }
  }

  deinit { timer?.invalidate() }

  /// This entire object exists only for an open menu. Each delta uses monotonic time.
  final class DetailReader {
    private let cpu = CPUUsageReader()
    private let processes = ProcessCPUReader()
    private let sensors = HIDTemperatures()
    private var previousNetwork: Counter?
    private var previousDisk: Counter?
    struct Counter {
      let identity: String
      let down: UInt64
      let up: UInt64
      let time: TimeInterval
    }
    static func bytes(_ bytes: UInt64) -> String {
      ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }
    static func rates(_ current: Counter, _ previous: Counter?) -> (String, String) {
      guard let previous, current.identity == previous.identity,
        current.time > previous.time, current.down >= previous.down, current.up >= previous.up
      else { return ("measuring…", "measuring…") }
      let elapsed = current.time - previous.time
      return (
        bytes(UInt64(Double(current.down - previous.down) / elapsed)) + "/s",
        bytes(UInt64(Double(current.up - previous.up) / elapsed)) + "/s"
      )
    }
    func sample() -> [Row] {
      cpu.sample(includeCores: true)
      let top = processes.sample()
      let cpuDetails =
        cpu.hasDelta
        ? cpu.cores.enumerated().map { "Core \($0.offset + 1): \(Int($0.element.rounded()))%" }
          + ["Top processes (100% = one core)"] + top : ["Measuring per-core and process CPU…"]
      let memory = MemoryPressure.read()
      let memoryDetails = [
        "Pressure: \(memory.pressurePercent)% · \(memory.levelName)",
        "Used: \(Self.bytes(memory.used)) / \(Self.bytes(memory.total))",
        "App: \(Self.bytes(memory.app))", "Wired: \(Self.bytes(memory.wired))",
        "Compressed: \(Self.bytes(memory.compressed))", "Cached: \(Self.bytes(memory.cached))",
        "Free: \(Self.bytes(memory.free))",
        "Swap: \(Self.bytes(memory.swapUsed)) / \(Self.bytes(memory.swapTotal))",
      ]
      return [
        Row(
          name: "CPU", summary: cpu.hasDelta ? "\(cpu.cpuPercent)%" : "Measuring…",
          details: cpuDetails),
        gpu(),
        Row(
          name: "Memory",
          summary: "\(Self.bytes(memory.used)) used · \(memory.pressurePercent)% pressure",
          details: memoryDetails),
        network(), disk(), battery(), sensors.sample(),
      ]
    }

    private func gpu() -> Row {
      var details: [String] = []
      var values: [Int] = []
      Self.services("IOAccelerator") { service in
        guard let stats = Self.property(service, "PerformanceStatistics") as? [String: Any],
          let value = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber
        else { return }
        let percent = max(0, min(100, value.intValue))
        values.append(percent)
        let name = Self.property(service, "model") as? String ?? "GPU \(values.count)"
        details.append("\(name): \(percent)%")
        for key in ["Renderer Utilization %", "Tiler Utilization %", "In use system memory"] {
          if let number = stats[key] as? NSNumber {
            details.append(
              "\(key): \(key.contains("memory") ? Self.bytes(number.uint64Value) : number.stringValue + "%")"
            )
          }
        }
      }
      return Row(
        name: "GPU",
        summary: values.isEmpty ? "Unavailable" : values.map { "\($0)%" }.joined(separator: " · "),
        details: details.isEmpty ? ["GPU utilisation unavailable on this hardware"] : details)
    }

    private func network() -> Row {
      let global =
        (SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString)
        ?? SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv6" as CFString)) as? [String: Any]
      guard let primary = global?["PrimaryInterface"] as? String else {
        previousNetwork = nil
        return Row(name: "Network ↓/↑", summary: "Offline", details: ["No primary interface"])
      }
      var interfaces: UnsafeMutablePointer<ifaddrs>?
      guard getifaddrs(&interfaces) == 0 else {
        previousNetwork = nil
        return Row(
          name: "Network ↓/↑", summary: "Unavailable", details: ["Could not read interfaces"])
      }
      defer { freeifaddrs(interfaces) }
      var cursor = interfaces
      while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        guard String(cString: entry.pointee.ifa_name) == primary,
          entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
          let raw = entry.pointee.ifa_data
        else { continue }
        let data = raw.assumingMemoryBound(to: if_data.self).pointee
        let current = Counter(
          identity: primary, down: UInt64(data.ifi_ibytes), up: UInt64(data.ifi_obytes),
          time: ProcessInfo.processInfo.systemUptime)
        let rates = Self.rates(current, previousNetwork)
        previousNetwork = current
        return Row(
          name: "Network ↓/↑", summary: "\(rates.0) / \(rates.1)",
          details: [
            "Primary interface: \(primary)", "Download: \(rates.0)", "Upload: \(rates.1)",
            "Received: \(Self.bytes(current.down))", "Sent: \(Self.bytes(current.up))",
          ])
      }
      previousNetwork = nil
      return Row(
        name: "Network ↓/↑", summary: "Unavailable", details: ["No byte counters for \(primary)"])
    }

    private func disk() -> Row {
      var filesystem = statfs()
      let spaceOK =
        statfs("/System/Volumes/Data", &filesystem) == 0 || statfs("/", &filesystem) == 0
      let free = UInt64(filesystem.f_bavail) * UInt64(filesystem.f_bsize)
      let total = UInt64(filesystem.f_blocks) * UInt64(filesystem.f_bsize)
      var read: UInt64 = 0
      var write: UInt64 = 0
      var ids: [UInt64] = []
      Self.services("IOBlockStorageDriver") { service in
        guard let stats = Self.property(service, "Statistics") as? [String: Any],
          let r = stats["Bytes (Read)"] as? NSNumber, let w = stats["Bytes (Write)"] as? NSNumber
        else { return }
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        ids.append(id)
        read += r.uint64Value
        write += w.uint64Value
      }
      let current = Counter(
        identity: ids.sorted().map(String.init).joined(separator: ","), down: read, up: write,
        time: ProcessInfo.processInfo.systemUptime)
      let rates = ids.isEmpty ? ("Unavailable", "Unavailable") : Self.rates(current, previousDisk)
      previousDisk = ids.isEmpty ? nil : current
      return Row(
        name: "Disk", summary: spaceOK ? "\(Self.bytes(free)) free" : "Unavailable",
        details: [
          spaceOK
            ? "Data volume: \(Self.bytes(free)) free / \(Self.bytes(total))"
            : "Data volume unavailable",
          "All physical disks read: \(rates.0)", "All physical disks write: \(rates.1)",
        ])
    }

    private func battery() -> Row {
      guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
      else {
        return Row(
          name: "Battery", summary: "Unavailable", details: ["Power-source information unavailable"]
        )
      }
      let descriptions = sources.compactMap {
        IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
      }
      guard
        let battery = descriptions.first(where: {
          $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        })
      else {
        return Row(
          name: "Battery", summary: "No battery", details: ["No internal battery reported"])
      }
      let current = (battery[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
      let max = (battery[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
      let percent = current.flatMap { c in
        max.flatMap { $0 > 0 ? Int((c * 100 / $0).rounded()) : nil }
      }
      let charging = battery[kIOPSIsChargingKey] as? Bool ?? false
      let charged = battery[kIOPSIsChargedKey] as? Bool ?? false
      let power = battery[kIOPSPowerSourceStateKey] as? String ?? "Unknown power source"
      let state = charging ? "Charging" : charged ? "Charged" : power
      let minutes = battery[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int ?? -1
      var details = [
        "Power source: \(power)", "State: \(state)",
        minutes > 0
          ? "\(charging ? "Until full" : "Remaining"): \(minutes / 60)h \(minutes % 60)m"
          : "Time remaining: calculating / unavailable",
      ]
      Self.services("AppleSmartBattery") { service in
        if let cycles = Self.property(service, "CycleCount") as? NSNumber {
          details.append("Cycles: \(cycles)")
        } else {
          details.append("Cycles: unavailable")
        }
        let design = (Self.property(service, "DesignCapacity") as? NSNumber)?.doubleValue
        let capacity =
          ((Self.property(service, "AppleRawMaxCapacity")
          ?? Self.property(service, "NominalChargeCapacity")) as? NSNumber)?.doubleValue
        if let design, let capacity, design > 0, capacity > 0 {
          details.append(
            "Health: \(Int(min(100, capacity / design * 100).rounded()))% of design capacity")
        } else {
          details.append("Health: unavailable")
        }
      }
      return Row(
        name: "Battery", summary: "\(percent.map { "\($0)%" } ?? "Unavailable") · \(state)",
        details: details)
    }

    static func services(_ name: String, _ body: (io_service_t) -> Void) {
      var iterator: io_iterator_t = 0
      guard
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator)
          == KERN_SUCCESS
      else { return }
      defer { IOObjectRelease(iterator) }
      while true {
        let service = IOIteratorNext(iterator)
        guard service != 0 else { break }
        body(service)
        IOObjectRelease(service)
      }
    }
    static func property(_ service: io_service_t, _ key: String) -> Any? {
      IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue()
    }
  }
}

/// One ps call per open-menu sample. Includes system-owned processes that
/// proc_pidinfo denies to this unprivileged app; ps reports CPU on a one-core scale.
private final class ProcessCPUReader {
  func sample() -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-Ao", "pid=,pcpu=,comm=", "-r"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return ["Process CPU unavailable"] }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return ["Process CPU unavailable"] }
    return String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(5).compactMap {
      line in
      let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
      guard fields.count == 3 else { return nil }
      let path = String(fields[2]).trimmingCharacters(in: .whitespaces)
      return "\(URL(fileURLWithPath: path).lastPathComponent) (\(fields[0])): \(fields[1])%"
    }
  }
}

/// Private HID APIs are resolved dynamically; unsupported systems return unavailable.
private final class HIDTemperatures {
  typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
  typealias Matching = @convention(c) (CFTypeRef, CFDictionary) -> Void
  typealias Services = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
  typealias Property = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
  typealias Event = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
  typealias Value = @convention(c) (CFTypeRef, Int32) -> Double
  private let smc = SMCTemperatures()
  private var library: UnsafeMutableRawPointer?
  private var client: CFTypeRef?
  private var services: [CFTypeRef] = []
  private var property: Property?
  private var event: Event?
  private var value: Value?
  init() {
    #if arch(arm64)
      library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
      guard let library else { return }
      func symbol<T>(_ name: String, _: T.Type) -> T? {
        dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
      }
      guard let create = symbol("IOHIDEventSystemClientCreate", Create.self),
        let matching = symbol("IOHIDEventSystemClientSetMatching", Matching.self),
        let copy = symbol("IOHIDEventSystemClientCopyServices", Services.self),
        let client = create(kCFAllocatorDefault)?.takeRetainedValue()
      else { return }
      self.client = client
      property = symbol("IOHIDServiceClientCopyProperty", Property.self)
      event = symbol("IOHIDServiceClientCopyEvent", Event.self)
      value = symbol("IOHIDEventGetFloatValue", Value.self)
      matching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
      services = copy(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
    #endif
  }
  func sample() -> SystemStats.Row {
    var readings: [(String, Double)] = []
    if let property, let event, let value {
      for service in services {
        guard let name = property(service, "Product" as CFString)?.takeRetainedValue() as? String,
          let reading = event(service, 15, 0, 0)?.takeRetainedValue()
        else { continue }
        let temperature = value(reading, 15 << 16)
        if temperature.isFinite && temperature > 0 && temperature < 150 {
          readings.append((name, temperature))
        }
      }
    }
    readings += smc.sample()
    var summaries: [String] = []
    for group in ["CPU", "GPU", "SoC"] {
      let values = readings.filter {
        let name = $0.0.lowercased()
        switch group {
        case "CPU": return name.hasPrefix("pacc") || name.hasPrefix("eacc") || name.contains("cpu")
        case "GPU": return name.hasPrefix("gpu")
        default: return name.hasPrefix("soc mtr") || name.hasPrefix("pmgr soc die")
        }
      }.map { $0.1 }
      summaries.append(
        "\(group) average: "
          + (values.isEmpty
            ? "Unavailable" : String(format: "%.1f°C", values.reduce(0, +) / Double(values.count))))
    }
    let hottest = readings.max { $0.1 < $1.1 }
    let summary = hottest.map { String(format: "%.1f°C hottest", $0.1) } ?? "Unavailable"
    summaries.append(
      hottest.map { "Hottest: \($0.0) · \(String(format: "%.1f°C", $0.1))" }
        ?? "No supported HID temperature sensors")
    return SystemStats.Row(name: "Temperatures", summary: summary, details: summaries)
  }
  deinit {
    services.removeAll()
    client = nil
    if let library { dlclose(library) }
  }
}
