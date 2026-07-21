import AppKit
import MachineSpiritKit
import SwiftUI

@main
struct MachineSpiritApp: App {
  @State private var state = AppState()

  var body: some Scene {
    WindowGroup("machine-spirit") {
      ContentView()
        .environment(state)
        .preferredColorScheme(.dark)
        .task {
          state.communeWithLiveConfig()
          state.loadSidecar()
          state.installKeyMonitor()
          state.installScrollMonitor()
          state.startSheolPolling()
          state.startConfigPolling()
        }
        // The fired ping (#36): machinespirit://fired?path=s/s/w/s —
        // the board pulses the route of the bind that just ran. The
        // existing window claims the event; without this, SwiftUI
        // spawns a NEW window per incoming URL (the ghost-window bug).
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL { url in
          guard url.host() == "fired",
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
              .queryItems?.first(where: { $0.name == "path" })?.value
          else { return }
          state.fireBind(atPath: path)
        }
    }
    .defaultSize(width: 1440, height: 900)
    .commands {
      // Open/relaunch the Leader Key launcher (the fork) from the app — the
      // suite is two processes that share one live config; this is the bridge
      // for testing a config edit or a fresh build without the terminal.
      CommandMenu("Launcher") {
        Button("Relaunch Leader Key") { state.relaunchLauncher() }
        Button("Open Leader Key Settings") { state.openLauncherSettings() }
      }
    }
  }
}
