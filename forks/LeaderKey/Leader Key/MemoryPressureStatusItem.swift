import Cocoa
import Darwin

/// Kernel readings shared by the compact bar and open Stats menu. No timer or UI owner.
enum MemoryPressure {
  struct Reading {
    var total: UInt64 = 0  // hw.memsize
    var app: UInt64 = 0  // internal - purgeable (Activity Monitor "App Memory")
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0  // purgeable + external (file-backed) — reclaimable
    var used: UInt64 = 0  // app + wired + compressed ("Memory Used")
    var free: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    /// kern.memorystatus_level — the kernel's "% of memory available".
    var availablePercent: Int = 100
    /// kern.memorystatus_vm_pressure_level — 1 normal · 2 warning · 4 critical.
    var vmPressureLevel: Int = 1
    var hasUsage = false
    var hasAvailablePercent = false
    var hasPressureLevel = false

    var levelName: String {
      guard hasPressureLevel else { return "Unavailable" }
      switch vmPressureLevel {
      case 4: return "Critical"
      case 2: return "Warning"
      case 1: return "Normal"
      default: return "Unavailable"
      }
    }

  }

  static func read(barOnly: Bool = false) -> Reading {
    var r = Reading()
    if !barOnly, let available = sysctlI32("kern.memorystatus_level") {
      r.availablePercent = Int(available)
      r.hasAvailablePercent = true
    }
    if let level = sysctlI32("kern.memorystatus_vm_pressure_level") {
      r.vmPressureLevel = Int(level)
      r.hasPressureLevel = true
    }

    r.total = sysctlU64("hw.memsize") ?? 0

    // VM page counts → byte breakdown (mirrors Activity Monitor's model).
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    if kr == KERN_SUCCESS {
      r.hasUsage = r.total > 0
      let ps = UInt64(vm_kernel_page_size)
      let wired = UInt64(stats.wire_count) * ps
      let compressed = UInt64(stats.compressor_page_count) * ps
      let purgeable = UInt64(stats.purgeable_count) * ps
      let external = UInt64(stats.external_page_count) * ps
      let internalPages = UInt64(stats.internal_page_count) * ps
      let app = internalPages > purgeable ? internalPages - purgeable : internalPages
      r.app = app
      r.wired = wired
      r.compressed = compressed
      r.cached = purgeable + external
      r.used = app + wired + compressed
      r.free =
        r.total > r.used + r.cached
        ? r.total - r.used - r.cached : UInt64(stats.free_count) * ps
    }

    guard !barOnly else { return r }
    // Swap.
    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
      r.swapTotal = swap.xsu_total
      r.swapUsed = swap.xsu_used
    }
    return r
  }

  private static func sysctlU64(_ name: String) -> UInt64? {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
  }

  private static func sysctlI32(_ name: String) -> Int32? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
  }

}
