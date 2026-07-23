import Cocoa
import Darwin

/// machine-spirit fork: the menu-bar **memory-pressure** readout.
///
/// Why this exists: Stats already shows RAM *usage* — but on macOS usage runs
/// high by design (the kernel hoards free RAM as file cache), so it's a poor
/// stress signal. What actually predicts a stall is *memory pressure*: how hard
/// the VM is working (compressing, swapping, reclaiming). This item surfaces
/// that as its own headline number, distinct from Stats' RAM %.
///
/// Performance: every reading is a syscall — `sysctlbyname` + one
/// `host_statistics64` call — no subprocess, no polling of `/usr/bin/*`. Reads
/// are microsecond-scale, so they run inline on the main thread (dispatching
/// them off-main would cost more than the work itself). Color/level transitions
/// are event-driven via a `DispatchSourceMemoryPressure`, so the icon flips the
/// instant the kernel changes state — the 2 s timer just keeps the % lively.
final class MemoryPressureStatusItem: NSObject, NSMenuDelegate {
  private var statusItem: NSStatusItem?
  private var pollTimer: Timer?
  private var pressureSource: DispatchSourceMemoryPressure?
  private var reading = Reading()

  // MARK: - The reading (one atomic snapshot of VM state)

  /// One snapshot. All byte fields are absolute; the percentages come straight
  /// from the kernel's memorystatus subsystem — the same numbers jetsam uses.
  private struct Reading {
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

    /// The headline: 100 − available. This is *pressure*, not usage — it stays
    /// low while the machine is healthy even when RAM "usage" looks high.
    var pressurePercent: Int { max(0, min(100, 100 - availablePercent)) }

    var levelName: String {
      switch vmPressureLevel {
      case 4: return "Critical"
      case 2: return "Warning"
      default: return "Normal"
      }
    }

    /// Icon/text tint. Calm (template-monochrome) while healthy so the menu bar
    /// stays quiet; escalates to orange/red only when the kernel says so.
    var levelColor: NSColor? {
      switch vmPressureLevel {
      case 4: return .systemRed
      case 2: return .systemOrange
      default: return nil  // nil ⇒ template image, adopts the menu-bar color
      }
    }
  }

  // MARK: - Lifecycle

  func enable() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.imagePosition = .imageLeading
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    statusItem = item

    refresh()  // paint immediately, don't wait for the first tick

    // Cheap enough to poll briskly — the whole read is a couple of syscalls.
    let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
      [weak self] _ in self?.refresh()
    }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer

    // Event-driven: flip the instant the kernel crosses a pressure threshold,
    // no matter where the 2 s poll happens to be.
    let src = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .main)
    src.setEventHandler { [weak self] in self?.refresh() }
    src.resume()
    pressureSource = src
  }

  func disable() {
    pollTimer?.invalidate()
    pollTimer = nil
    pressureSource?.cancel()
    pressureSource = nil
    if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
    statusItem = nil
  }

  // MARK: - Refresh

  private func refresh() {
    reading = Self.read()
    updateButton()
  }

  private func updateButton() {
    guard let button = statusItem?.button else { return }
    let p = reading.pressurePercent
    button.image = Self.gaugeImage(percent: p, tint: reading.levelColor)
    button.title = " \(p)%"
    button.toolTip =
      "Memory pressure: \(reading.levelName) · \(p)% "
      + "(RAM available \(reading.availablePercent)%)\n"
      + "Used \(Self.fmt(reading.used)) of \(Self.fmt(reading.total)) · "
      + "Cached \(Self.fmt(reading.cached))"
      + (reading.swapTotal > 0 ? " · Swap \(Self.fmt(reading.swapUsed))" : "")
  }

  /// A gauge whose needle tracks the pressure %, tinted by kernel pressure
  /// level. Falls back gracefully if a needle variant is unavailable.
  private static func gaugeImage(percent: Int, tint: NSColor?) -> NSImage? {
    let bucket: Int
    switch percent {
    case ..<17: bucket = 0
    case ..<42: bucket = 33
    case ..<58: bucket = 50
    case ..<84: bucket = 67
    default: bucket = 100
    }
    let candidates = [
      "gauge.with.dots.needle.bottom.\(bucket)percent",
      "gauge.with.dots.needle.bottom.50percent",
      "gauge.medium",
      "memorychip",
    ]
    var base: NSImage?
    for name in candidates {
      if let img = NSImage(systemSymbolName: name, accessibilityDescription: "memory pressure") {
        base = img
        break
      }
    }
    guard let image = base else { return nil }
    if let tint {
      let cfg = NSImage.SymbolConfiguration(paletteColors: [tint])
      let tinted = image.withSymbolConfiguration(cfg) ?? image
      tinted.isTemplate = false
      return tinted
    }
    image.isTemplate = true  // healthy → adopt the menu-bar's own color
    return image
  }

  // MARK: - Reading the kernel (all syscalls, no subprocess)

  private static func read() -> Reading {
    var r = Reading()
    r.total = sysctlU64("hw.memsize") ?? 0
    r.availablePercent = Int(sysctlI32("kern.memorystatus_level") ?? 100)
    r.vmPressureLevel = Int(sysctlI32("kern.memorystatus_vm_pressure_level") ?? 1)

    // VM page counts → byte breakdown (mirrors Activity Monitor's model).
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    if kr == KERN_SUCCESS {
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

  private static func fmt(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
  }

  // MARK: - Dropdown (rebuilt fresh on every open)

  func menuNeedsUpdate(_ menu: NSMenu) {
    refresh()  // accurate the instant it appears
    menu.removeAllItems()

    menu.addItem(coloredHeader("Memory Pressure — \(reading.levelName)", color: reading.levelColor))
    menu.addItem(row("Pressure", "\(reading.pressurePercent)%"))
    menu.addItem(row("RAM available", "\(reading.availablePercent)%"))

    menu.addItem(.separator())
    let usedPct = reading.total > 0 ? Int((reading.used * 100) / reading.total) : 0
    menu.addItem(row("Used", "\(fmt(reading.used)) / \(fmt(reading.total))  (\(usedPct)%)"))
    menu.addItem(row("  App", fmt(reading.app)))
    menu.addItem(row("  Wired", fmt(reading.wired)))
    menu.addItem(row("  Compressed", fmt(reading.compressed)))
    menu.addItem(row("Cached files", fmt(reading.cached)))
    menu.addItem(row("Free", fmt(reading.free)))
    menu.addItem(
      row("Swap", reading.swapTotal > 0 ? "\(fmt(reading.swapUsed)) / \(fmt(reading.swapTotal))" : "none"))

    menu.addItem(.separator())
    let am = NSMenuItem(
      title: "Open Activity Monitor…", action: #selector(openActivityMonitor), keyEquivalent: "")
    am.target = self
    menu.addItem(am)
  }

  private func fmt(_ bytes: UInt64) -> String { Self.fmt(bytes) }

  /// A non-interactive "Label            value" row. The value is dimmed and
  /// right-feeling via a tab; menu rows aren't a grid, so we keep it simple.
  private func row(_ label: String, _ value: String) -> NSMenuItem {
    let item = NSMenuItem(title: "\(label):  \(value)", action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private func coloredHeader(_ title: String, color: NSColor?) -> NSMenuItem {
    guard let color else {
      if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.isEnabled = false
      return item
    }
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .foregroundColor: color,
        .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
      ])
    return item
  }

  @objc private func openActivityMonitor() {
    NSWorkspace.shared.open(
      URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
  }
}
