import Foundation
import IOKit.ps
import Darwin

func cpuTicks() throws -> [UInt32] {
    var count: mach_msg_type_number_t = 0
    var cpus: natural_t = 0
    var info: processor_info_array_t?
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
          let info else { throw Failure("cannot read host CPU counters") }
    defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(count) * MemoryLayout<integer_t>.size)) }
    return (0..<Int(count)).map { UInt32(bitPattern: info[$0]) }
}

func stats() throws -> Output {
    let start = try cpuTicks()
    Thread.sleep(forTimeInterval: 0.25)
    let end = try cpuTicks()
    guard start.count == end.count else { throw Failure("CPU topology changed during sampling; retry") }
    var total: UInt64 = 0
    var idle: UInt64 = 0
    for index in start.indices {
        let delta = UInt64(end[index] &- start[index])
        total += delta
        if index % Int(CPU_STATE_MAX) == Int(CPU_STATE_IDLE) { idle += delta }
    }
    let cpu = total == 0 ? 0 : Double(total - idle) / Double(total) * 100
    var vm = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &vm) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { throw Failure("cannot read host memory counters") }
    var pageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { throw Failure("cannot read page size") }
    let physical = ProcessInfo.processInfo.physicalMemory
    let available = (UInt64(vm.free_count) + UInt64(vm.inactive_count) + UInt64(vm.speculative_count)) * UInt64(pageSize)
    let pressure = max(0, min(100, (1 - Double(available) / Double(physical)) * 100))
    var level: Int32 = 0
    var levelSize = MemoryLayout.size(ofValue: level)
    let levelOK = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0
    let levelName = levelOK ? ([1: "normal", 2: "warning", 4: "critical"][Int(level)] ?? "unknown") : "unavailable"
    var swap = xsw_usage()
    var swapSize = MemoryLayout.size(ofValue: swap)
    guard sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 else { throw Failure("cannot read swap usage") }
    var battery: Double?
    if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
       let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Double,
                  let max = description[kIOPSMaxCapacityKey] as? Double, max > 0 else { continue }
            battery = current / max * 100
            break
        }
    }
    let uptime = ProcessInfo.processInfo.systemUptime
    let note = "memoryPressurePercent is an estimate: 100 × (1 − (free + inactive + speculative pages) / physical pages), not Activity Monitor's pressure graph. pressureLevel is the kernel signal."
    return Output(json: ["cpuPercent": cpu, "sampleMilliseconds": 250, "memoryPressurePercent": pressure,
                         "pressureLevel": levelName, "physicalMemoryBytes": physical,
                         "swap": ["usedBytes": swap.xsu_used, "totalBytes": swap.xsu_total],
                         "batteryPercent": battery as Any? ?? NSNull(), "uptimeSeconds": uptime, "notes": [note]],
                  text: String(format: "CPU %.1f%% (250 ms) | memory pressure estimate %.1f%% (%@) | swap %.2f / %.2f GiB | battery %@ | uptime %.0fs\nNote: %@",
                               cpu, pressure, levelName, Double(swap.xsu_used) / 1_073_741_824,
                               Double(swap.xsu_total) / 1_073_741_824, battery.map { String(format: "%.0f%%", $0) } ?? "n/a", uptime, note))
}
