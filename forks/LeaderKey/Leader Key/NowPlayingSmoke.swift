#if NOW_PLAYING_SMOKE
  // Standalone harness; inert in the app target. Build from the fork directory:
  // clang -O2 -c 'Leader Key/NowPlayingMeter.c' -o "$OUT/meter.o"
  // swiftc -D NOW_PLAYING_SMOKE -import-objc-header 'Leader Key/NowPlayingMeter.h' \
  //   'Leader Key/NowPlayingAudio.swift' 'Leader Key/NowPlayingMenu.swift' \
  //   'Leader Key/CompactBar.swift' 'Leader Key/NowPlayingSmoke.swift' "$OUT/meter.o" \
  //   -o "$OUT/AudioSmoke.app/Contents/MacOS/AudioSmoke"
  // Give the harness bundle its own Info.plist with NSAudioCaptureUsageDescription.
  // Run AudioSmoke OUTPUT_DIRECTORY [--fixture] [--draw]. Does not open/replace the daily-driver app.
  import Cocoa
  import AVFoundation
  import Darwin

  private final class FakeAudioTap: NowPlayingTapHandle {
    let level = try! NowPlayingLevel()
    private var stopped = false
    let didStop: () -> Void
    init(didStop: @escaping () -> Void) { self.didStop = didStop }
    func stop() {
      if !stopped {
        stopped = true
        didStop()
      }
    }
    deinit { precondition(stopped, "Leaked tap") }
  }

  @main struct NowPlayingSmoke {
    static func wait(_ seconds: Double) {
      RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    static func close(_ model: NowPlayingMenuSection) {
      let drained = DispatchSemaphore(value: 0)
      model.close { drained.signal() }
      precondition(model.timersAreNil && model.sessionIsNil && model.rows.isEmpty)
      precondition(drained.wait(timeout: .now() + 10) == .success, "Audio teardown timed out")
      let count = model.sampleCount
      wait(1.2)
      precondition(model.sampleCount == count, "Sample published after close")
    }
    static func cpuTime() -> Double {
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(
        usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    static func measure(_ seconds: Double) -> Double {
      let cpu = cpuTime()
      let start = ProcessInfo.processInfo.systemUptime
      wait(seconds)
      return (cpuTime() - cpu) / (ProcessInfo.processInfo.systemUptime - start) * 100
    }
    // Exercise the real menu-item views at 20 fps in an offscreen window. This
    // includes AppKit drawing but excludes WindowServer composition/deployed app.
    static func measureOpen(_ menu: NSMenu, seconds: Double) -> Double {
      let views = menu.items.compactMap(\.view)
      let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: max(1, views.count) * 28))
      canvas.appearance = NSAppearance(named: .darkAqua)
      let window = NSWindow(
        contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer {
        window.contentView = nil
        window.close()
      }
      window.contentView = canvas
      for (index, view) in views.enumerated() {
        view.frame = NSRect(x: 0, y: index * 28, width: 430, height: 28)
        canvas.addSubview(view)
      }
      window.display()
      let drawing = Timer(timeInterval: 0.05, repeats: true) { _ in canvas.displayIfNeeded() }
      RunLoop.main.add(drawing, forMode: .common)
      let result = measure(seconds)
      drawing.invalidate()
      for view in views { view.removeFromSuperview() }
      return result
    }
    static func render(_ model: NowPlayingMenuSection, to url: URL) throws {
      let height =
        40 + max(1, model.rows.count) * 28
        + (model.metersUnavailable && !model.rows.isEmpty ? 28 : 0)
      let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: height))
      canvas.appearance = NSAppearance(named: .darkAqua)
      canvas.wantsLayer = true
      canvas.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
      let header = NSTextField(labelWithString: "")
      header.attributedStringValue = NSMenuItem.msSectionHeader(title: "Now Playing")
        .attributedTitle!
      header.frame = NSRect(x: 14, y: height - 27, width: 400, height: 16)
      canvas.addSubview(header)
      for (index, row) in model.rows.enumerated() {
        let view = NowPlayingRowView(name: row.name, icon: row.app?.icon, levels: row.levels)
        view.frame = NSRect(x: 0, y: height - 62 - index * 28, width: 430, height: 28)
        view.updateLevel()
        canvas.addSubview(view)
      }
      if model.rows.isEmpty || model.metersUnavailable {
        let label = NSTextField(
          labelWithString: model.rows.isEmpty
            ? "silence" : "meters need System Audio Recording permission")
        label.font = NSFont.menuFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 7, width: 410, height: 20)
        canvas.addSubview(label)
      }
      // Offscreen window supplies backing scale, appearance, and font rendering.
      let window = NSWindow(
        contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer {
        window.contentView = nil
        window.close()
      }
      window.contentView = canvas
      window.display()
      let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
      canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
    static func renderMeterFixtures(to url: URL) throws {
      let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 96))
      canvas.appearance = NSAppearance(named: .darkAqua)
      canvas.wantsLayer = true
      canvas.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
      let header = NSTextField(labelWithString: "METER FIXTURES · SYNTHETIC")
      header.font = .systemFont(ofSize: 10, weight: .semibold)
      header.frame = NSRect(x: 14, y: 69, width: 400, height: 16)
      canvas.addSubview(header)
      for (index, amplitude) in [Float(0.25), Float(0.9)].enumerated() {
        let level = try NowPlayingLevel()
        var samples = [amplitude, -amplitude]
        samples.withUnsafeMutableBytes { bytes in
          var input = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
              mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
          var output = AudioBufferList()
          var time = AudioTimeStamp()
          _ = MSMeterIOProc(
            0, &time, &input, &time, &output, &time, UnsafeMutableRawPointer(level.pointer))
        }
        let view = NowPlayingRowView(
          name: index == 0 ? "Green · −12 dBFS" : "Amber · near clipping", icon: nil,
          levels: [level])
        view.frame = NSRect(x: 0, y: 34 - index * 28, width: 430, height: 28)
        view.updateLevel()
        canvas.addSubview(view)
      }
      let window = NSWindow(
        contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer {
        window.contentView = nil
        window.close()
      }
      window.contentView = canvas
      window.display()
      let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
      canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    // Separate output-producing PID, -80 dBFS: nearly inaudible, deterministic,
    // and unrelated to the owner's running apps. Only used with --fixture.
    static func fixtureTone() throws {
      let engine = AVAudioEngine()
      let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
      var phase = 0.0
      let source = AVAudioSourceNode { _, _, frames, audio in
        let buffers = UnsafeMutableAudioBufferListPointer(audio)
        for frame in 0..<Int(frames) {
          let value = Float(sin(phase) * 0.0001)
          phase += 2 * .pi * 440 / 48000
          if phase > 2 * .pi { phase -= 2 * .pi }
          for buffer in buffers {
            buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
          }
        }
        return noErr
      }
      engine.attach(source)
      engine.connect(source, to: engine.mainMixerNode, format: format)
      try engine.start()
      Thread.sleep(forTimeInterval: 8)
      engine.stop()
    }
    static func main() throws {
      if CommandLine.arguments.contains("--fixture-tone") {
        try fixtureTone()
        return
      }
      setbuf(stdout, nil)
      _ = NSApplication.shared
      NSApp.setActivationPolicy(.accessory)
      let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
      if CommandLine.arguments.contains("--render-only") {
        try renderMeterFixtures(to: output.appendingPathComponent("meter-fixtures.png"))
        let model = NowPlayingMenuSection()
        let menu = NSMenu()
        model.append(to: menu)
        model.open()
        wait(4.5)
        try render(model, to: output.appendingPathComponent("now-playing.png"))
        close(model)
        return
      }
      // Verify real callback math and stale-value handling without a tap.
      let level = try NowPlayingLevel()
      var samples: [Float] = [0.5, -0.5, 0.5, -0.5]
      samples.withUnsafeMutableBytes { bytes in
        var input = AudioBufferList(
          mNumberBuffers: 1,
          mBuffers: AudioBuffer(
            mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
        var time = AudioTimeStamp()
        var output = AudioBufferList()
        _ = MSMeterIOProc(
          0, &time, &input, &time, &output, &time, UnsafeMutableRawPointer(level.pointer))
      }
      precondition(abs(level.levels.rms - 0.5) < 0.0001 && level.levels.peak == 0.5)
      wait(0.3)
      precondition(level.levels.rms == 0, "Stale level did not expire")
      print("PASS atomic RMS/peak and stale-level expiry")
      try renderMeterFixtures(to: output.appendingPathComponent("meter-fixtures.png"))

      let process = NowPlayingProcess(object: 123, pid: getpid())
      var attempts = 0
      let denied = NowPlayingMenuSection()
      let deniedMenu = NSMenu()
      denied.enumerate = { [process] }
      denied.makeTap = { _ in
        attempts += 1
        throw NSError(domain: "SimulatedTCCDenial", code: 1)
      }
      deniedMenu.removeAllItems()
      denied.append(to: deniedMenu)
      denied.open()
      wait(2.2)
      precondition(
        denied.rows.count == 1 && denied.rows[0].levels.isEmpty && denied.metersUnavailable
          && attempts == 1)
      precondition(
        deniedMenu.items.filter {
          $0.title == "meters need System Audio Recording permission" && !$0.isEnabled
        }.count == 1)
      try render(denied, to: output.appendingPathComponent("permission-fallback.png"))
      close(denied)
      deniedMenu.removeAllItems()
      denied.append(to: deniedMenu)
      denied.open()
      wait(1.2)
      close(denied)
      precondition(attempts == 1, "Permission retried after reopen")
      print("PASS denied capture: app row retained, one disabled hint, no retries across reopen")

      let lifecycle = NowPlayingMenuSection()
      let lifecycleMenu = NSMenu()
      var stops = 0
      lifecycle.enumerate = { [process] }
      lifecycle.makeTap = { _ in FakeAudioTap { stops += 1 } }
      lifecycleMenu.removeAllItems()
      lifecycle.append(to: lifecycleMenu)
      lifecycle.open()
      wait(0.3)
      precondition(lifecycle.rows.count == 1 && !lifecycle.timersAreNil)
      let beforeTracking = lifecycle.sampleCount
      let trackingEnd = Date().addingTimeInterval(1.2)
      while Date() < trackingEnd { RunLoop.main.run(mode: .eventTracking, before: trackingEnd) }
      precondition(
        lifecycle.sampleCount > beforeTracking, "Enumeration did not tick in menu tracking mode")
      close(lifecycle)
      precondition(stops == 1)
      print(
        "PASS common-mode timer and tap teardown; timers/session/taps/IOProcs/devices=nil after close"
      )

      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      lifecycle.enumerate = {
        entered.signal()
        release.wait()
        return [process]
      }
      lifecycleMenu.removeAllItems()
      lifecycle.append(to: lifecycleMenu)
      lifecycle.open()
      precondition(entered.wait(timeout: .now() + 2) == .success)
      lifecycle.close()
      release.signal()
      wait(0.3)
      precondition(lifecycle.rows.isEmpty && lifecycle.sessionIsNil && stops == 1)
      print("PASS close during enumeration: no late tap creation or UI publication")

      let model = NowPlayingMenuSection()
      let menu = NSMenu()
      model.append(to: menu)
      model.open()
      let fixture = Process()
      if CommandLine.arguments.contains("--fixture") {
        fixture.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        fixture.arguments = ["--fixture-tone"]
        try fixture.run()
      }
      wait(4.5)
      var maximumRMS: [String: Float] = [:]
      var maximumPeak: [String: Float] = [:]
      var maximumPeakByPID: [pid_t: Float] = [:]
      let signalTimer = Timer(timeInterval: 0.05, repeats: true) { _ in
        for row in model.rows {
          for level in row.levels {
            let value = level.levels
            maximumRMS[row.name] = max(maximumRMS[row.name] ?? 0, value.rms)
            maximumPeak[row.name] = max(maximumPeak[row.name] ?? 0, value.peak)
            maximumPeakByPID[row.pid] = max(maximumPeakByPID[row.pid] ?? 0, value.peak)
          }
        }
      }
      RunLoop.main.add(signalTimer, forMode: .common)
      wait(2)
      signalTimer.invalidate()
      for row in model.rows {
        print(
          "SIGNAL \(row.name) maxRMS=\(maximumRMS[row.name] ?? 0) maxPeak=\(maximumPeak[row.name] ?? 0)"
        )
        print(
          "LIVE \(row.name) pid=\(row.pid) meters=\(row.levels.count) receivedIO=\(row.levels.contains { $0.hasReceivedAudio })"
        )
      }
      if model.rows.isEmpty { print("LIVE silence") }
      print(
        "LIVE permissionFallback=\(model.metersUnavailable) enumerationFailed=\(model.enumerationFailed)"
      )
      try render(model, to: output.appendingPathComponent("now-playing.png"))
      let includeDrawing = CommandLine.arguments.contains("--draw")
      let openCPU = includeDrawing ? measureOpen(menu, seconds: 10) : measure(10)
      close(model)
      let closedCPU = measure(10)
      print(
        String(
          format:
            "CPU isolated audio model (offscreen drawing=%@): open %.3f%% (%.1f%%), closed %.3f%% (%.1f%%), 10s windows",
          includeDrawing ? "yes" : "no", openCPU, openCPU, closedCPU, closedCPU))
      // CPU is reported, not asserted: a process-level reading includes AppKit
      // housekeeping outside the audio model. Zero audio work is asserted via
      // nil handles/timers and no samples delivered throughout the closed run.
      precondition(model.timersAreNil && model.sessionIsNil)
      if fixture.executableURL != nil {
        precondition(
          (maximumPeakByPID[fixture.processIdentifier] ?? 0) > 0, "Quiet fixture was not captured")
        precondition(!fixture.isRunning, "Fixture did not stop")
        print("PASS real process tap captured nonzero -80 dBFS fixture")
      }
      print(
        "PASS live close, nil resources, no closed sampling. PNG: \(output.appendingPathComponent("now-playing.png").path)"
      )
    }
  }
#endif
