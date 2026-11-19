import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let state = AppState()
  var openBoardAction: (() -> Void)?
  private var overlay: TypingOverlay?
  private var closeObserver: NSObjectProtocol?
  private var launched = false

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    installURLHandler()
    state.start()
    overlay = TypingOverlay(state: state)
    let center = DistributedNotificationCenter.default()
    center.addObserver(self, selector: #selector(navigation(_:)),
      name: Notification.Name("com.machinespirit.leader.nav"), object: nil,
      suspensionBehavior: .deliverImmediately)
    center.addObserver(self, selector: #selector(fired(_:)),
      name: Notification.Name("com.machinespirit.leader.fired"), object: nil,
      suspensionBehavior: .deliverImmediately)
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
      case "board": openBoard()
      case "fired":
        if let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?.first(where: { $0.name == "path" })?.value {
          state.fireBind(atPath: path)
        }
      default: break
      }
    }
  }

  func openBoard() {
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
    if navigationState == "hidden" { overlay?.hide(); return }
    guard navigationState == "shown", let path = info["path"] as? String else { return }
    overlay?.show(path: path, screen: info["screen"] as? String)
  }

  @objc private func fired(_ notification: Notification) {
    if let path = notification.userInfo?["path"] as? String { state.fireBind(atPath: path) }
  }

  func applicationWillTerminate(_ notification: Notification) {
    NSAppleEventManager.shared().removeEventHandler(
      forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    DistributedNotificationCenter.default().removeObserver(self)
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    state.saveSidecar()
    state.shutdown()
  }
}
