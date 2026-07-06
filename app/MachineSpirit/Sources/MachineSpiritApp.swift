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
          state.installTabMonitor()
          state.startSheolPolling()
        }
    }
    .defaultSize(width: 1440, height: 900)
  }
}
