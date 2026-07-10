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
  }
}
