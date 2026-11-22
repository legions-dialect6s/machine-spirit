import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let state: AppState

  init(state: AppState, capsFollower: CapsFollower = CapsFollower()) {
    self.state = state; self.capsFollower = capsFollower; super.init()
  }
  // NSApplicationDelegateAdaptor instantiates via the ObjC init(); a Swift
  // default argument does not provide one (crashed at launch).
  override convenience init() { self.init(state: AppState()) }
  var openBoardAction: (() -> Void)?
  private(set) var overlay: TypingOverlay?
  let hud = OverlayHUD()
  private let audioFeedback = ShortcutAudioFeedback()
  let capsFollower: CapsFollower
  private var closeObserver: NSObjectProtocol?
  private var launched = false
  private(set) var transientBoard = false

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    installURLHandler()
    state.start()
    installOverlayObservers()
    capsFollower.start()
  }

  // A namespaced center allows the smoke harness to exercise real IPC without
  // sending synthetic navigation to the installed app.
  func installOverlayObservers(prefix: String = "com.machinespirit.leader", placementPreview: PlacementPreview = PlacementPreview()) {
    let center = DistributedNotificationCenter.default()
    center.addObserver(self, selector: #selector(navigation(_:)),
      name: Notification.Name("\(prefix).nav"), object: nil,
      suspensionBehavior: .deliverImmediately)
    center.addObserver(self, selector: #selector(fired(_:)),
      name: Notification.Name("\(prefix).fired"), object: nil,
      suspensionBehavior: .deliverImmediately)
    center.addObserver(self, selector: #selector(feedback(_:)),
      name: Notification.Name("\(prefix).feedback"), object: nil,
      suspensionBehavior: .deliverImmediately)
    center.addObserver(self, selector: #selector(placement(_:)),
      name: Notification.Name("\(prefix).placement"), object: nil, suspensionBehavior: .deliverImmediately)
    center.addObserver(self, selector: #selector(placementMiss(_:)),
      name: Notification.Name("\(prefix).placement.miss"), object: nil, suspensionBehavior: .deliverImmediately)
    center.addObserver(self, selector: #selector(windowFocus(_:)),
      name: Notification.Name("\(prefix).window.focus"), object: nil, suspensionBehavior: .deliverImmediately)
    overlay = TypingOverlay(state: state, placementPreview: placementPreview)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // SwiftUI's default GetURL handler also routes URLs through its scene
    // machinery, even when the delegate implements application(_:open:).
    // Install before cold-launch routing, then reassert after SwiftUI setup:
    // fired pings are model updates, never scene requests.
    installURLHandler()
    launched = true
  }

  private func installURLHandler() {
    NSAppleEventManager.shared().setEventHandler(self,
      andSelector: #selector(openURL(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
  }

  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

  @objc private func openURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
    guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
      let url = URL(string: text) else { return }
    application(NSApp, open: [url])
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if launched { openBoard() }
    return false
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.scheme?.lowercased() == "machinespirit" {
      switch url.host?.lowercased() {
      case "board":
        let transient = URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?.first(where: { $0.name == "transient" })?.value == "1"
        openBoard(transient: transient)
      case "hud":
        capsFollower.receiveHUD(url: url)
        hud.show(url: url)
      case "fired":
        if let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?.first(where: { $0.name == "path" })?.value {
          state.fireBind(atPath: path)
        }
      default: break
      }
    }
  }

  func openBoard(transient: Bool = false) {
    transientBoard = transient
    state.boardOpen = true
    NSApp.setActivationPolicy(.regular)
    openBoardAction?()
    if let window = state.boardWindow {
      window.deminiaturize(nil)
      window.makeKeyAndOrderFront(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
    state.startSheolPolling()
    state.disturb()
  }

  func applicationDidResignActive(_ notification: Notification) {
    guard transientBoard, state.boardOpen else { return }
    // Order out the same window; selection/viewport live in AppState. Drop
    // expensive board content and polling without saving or resetting them.
    state.boardWindow?.orderOut(nil)
    state.closeBoard(persist: false)
    NSApp.setActivationPolicy(.accessory)
  }

  func attachBoard(_ window: NSWindow) {
    guard state.boardWindow !== window else { return }
    state.boardWindow = window
    window.minSize = NSSize(width: 420, height: 320)
    let chromeHeight = window.frame.height - window.contentLayoutRect.height
    // SwiftUI also installs content-size constraints. Account for the title
    // bar there, otherwise a 320pt content floor becomes a 352pt window.
    DispatchQueue.main.async { [weak self] in
      self?.state.boardMinimumContentHeight = max(0, 320 - chromeHeight)
    }
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.state.closeBoard()
        NSApp.setActivationPolicy(.accessory)
      }
    }
  }

  @objc private func navigation(_ notification: Notification) {
    guard let info = notification.userInfo,
      let navigationState = info["state"] as? String else { return }
    if navigationState == "hidden" { audioFeedback.previousPath = ""; overlay?.hide(); return }
    guard navigationState == "shown" || navigationState == "hold", let path = info["path"] as? String else { return }
    if navigationState == "shown" { audioFeedback.navigation(path: path) }
    overlay?.show(path: path, screen: info["screen"] as? String, preview: navigationState == "shown" && path == "space", held: navigationState == "hold")
  }

  @objc private func feedback(_ notification: Notification) {
    guard let kind = notification.userInfo?["kind"] as? String else { return }
    if kind == "miss" { audioFeedback.emit(.miss, spoken: "No match") }
    overlay?.feedback(kind: kind, path: notification.userInfo?["path"] as? String)
  }

  @objc private func placement(_ notification: Notification) {
    guard let info = notification.userInfo, let pid = info["pid"] as? NSNumber,
          let raw = info["frame"] as? String, let name = info["mode"] as? String,
          let mode = Placement(rawValue: name),
          UserDefaults(suiteName: "com.machinespirit.leader-key")?.object(forKey: "msGraphOverlayEnabled") as? Bool != false else { return }
    overlay?.placementPreview.commandDestination(pid: pid.int32Value, id: (info["windowID"] as? NSNumber)?.uint32Value,
                                                frame: NSRectFromString(raw), mode: mode,
                                                sourceFrame: (info["sourceFrame"] as? String).map(NSRectFromString))
  }

  @objc private func placementMiss(_ notification: Notification) {
    guard let reason = notification.userInfo?["reason"] as? String else { return }
    audioFeedback.emit(.miss, spoken: reason)
    guard UserDefaults(suiteName: "com.machinespirit.leader-key")?.object(forKey: "msGraphOverlayEnabled") as? Bool != false else { return }
    overlay?.placementPreview.commandMiss(reason: reason)
  }

  @objc private func windowFocus(_ notification: Notification) {
    guard let pid = notification.userInfo?["pid"] as? NSNumber,
          UserDefaults(suiteName: "com.machinespirit.leader-key")?.object(forKey: "msGraphOverlayEnabled") as? Bool != false else { return }
    overlay?.placementPreview.commandFocus(pid: pid.int32Value, id: (notification.userInfo?["windowID"] as? NSNumber)?.uint32Value)
  }

  @objc private func fired(_ notification: Notification) {
    guard let path = notification.userInfo?["path"] as? String,
      let route = state.route(atPath: path), route.count > 1 else { return }
    if let id = route.last, let cue = LaunchCue(action: state.model?.node(withID: id)?.action),
       UserDefaults(suiteName: "com.machinespirit.leader-key")?.object(forKey: "msGraphOverlayEnabled") as? Bool != false {
      overlay?.placementPreview.launch(cue, path: path, fx: OverlayFX())
    } else { overlay?.placementPreview.fire(path: path) }
    state.fireBind(atPath: path)
    let nodes = route.compactMap { state.model?.node(withID: $0) }
    let keyPath = nodes.compactMap(\.key).map { $0 == " " ? "space" : $0 }.joined(separator: "/")
    let label = nodes.last?.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    audioFeedback.emit(.command, spoken: label.isEmpty ? keyPath.replacingOccurrences(of: "/", with: " ") : label)
    state.stats.record(path: keyPath, windowPlacement: nodes.contains(where: StatsStore.isWindowPlacement))
  }

  func applicationWillTerminate(_ notification: Notification) {
    capsFollower.stop()
    NSAppleEventManager.shared().removeEventHandler(
      forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    DistributedNotificationCenter.default().removeObserver(self)
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    state.stats.flush()
    state.saveSidecar()
    state.shutdown()
  }
}

/// Optional feedback for leader input only. The quiet default creates no audio objects.
@MainActor
private final class ShortcutAudioFeedback {
  enum Cue { case key, command, miss }
  var previousPath = ""
  private var speech: AVSpeechSynthesizer?
  private var sounds: [String: AVAudioPlayer] = [:]
  private var lastCue: (kind: Cue, text: String, time: TimeInterval)?
  private var lastTone: TimeInterval = -.infinity

  func navigation(path: String) {
    defer { previousPath = path }
    guard path != previousPath, !path.isEmpty,
          previousPath.isEmpty || path.hasPrefix(previousPath + "/"),
          let key = path.split(separator: "/").last else { return }
    emit(.key, spoken: String(key))
  }

  func emit(_ cue: Cue, spoken: String) {
    let mode = UserDefaults.standard.string(forKey: "msFX.audioFeedback")
    guard mode == "sounds" || mode == "speech" else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if mode == "sounds", cue == .key { return }
    let previous = lastCue
    lastCue = (cue, spoken, now)
    if let previous, previous.kind == cue, previous.text == spoken, now - previous.time < 0.32 { return }
    if mode == "sounds" {
      if cue == .miss, previous?.kind == .command {
        sounds["ShortcutTap"]?.stop()
      } else if now - lastTone < 0.20 { return }
      let name = cue == .miss ? "ShortcutMiss" : "ShortcutTap"
      if sounds[name] == nil, let asset = NSDataAsset(name: name) {
        sounds[name] = try? AVAudioPlayer(data: asset.data)
      }
      guard let player = sounds[name], !player.isPlaying else { return }
      player.numberOfLoops = 0
      player.currentTime = 0
      if player.play() { lastTone = now }
      return
    }
    // Repeated navigation or held keys must not restart an utterance mid-syllable.
    if speech == nil { speech = AVSpeechSynthesizer() }
    if speech?.isSpeaking == true {
      guard cue != .key else { return }
      speech?.stopSpeaking(at: .immediate)
    }
    let utterance = AVSpeechUtterance(string: String(spoken.prefix(64)))
    utterance.rate = 0.55
    speech?.speak(utterance)
  }
}
