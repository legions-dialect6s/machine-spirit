import AppKit
import SwiftUI

@main
struct MachineSpiritApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @Environment(\.openWindow) private var openWindow

  var body: some Scene {
    let _ = delegate.openBoardAction = { openWindow(id: "board") }
    Window("machine-spirit", id: "board") {
      BoardRoot(delegate: delegate)
        .environment(delegate.state)
        .preferredColorScheme(.dark)
    }
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
    .defaultSize(width: 1000, height: 700)
    .commands {
      CommandMenu("Launcher") {
        Button("Open Board") { delegate.openBoard() }
        Button("Relaunch Leader Key") { delegate.state.relaunchLauncher() }
        Button("Open Leader Key Settings") { delegate.state.openLauncherSettings() }
      }
    }
  }
}

/// The scene may be cached by SwiftUI. Its expensive content is explicitly
/// removed on close, so no hidden Canvas, terminal, or render clock survives.
private struct BoardRoot: View {
  @Environment(AppState.self) private var state
  let delegate: AppDelegate

  var body: some View {
    Group {
      if state.boardOpen { ContentView() }
      else { Color.clear }
    }
    .frame(minWidth: 420, minHeight: state.boardMinimumContentHeight)
    .background(BoardWindowReader(delegate: delegate))
  }
}

private struct BoardWindowReader: NSViewRepresentable {
  let delegate: AppDelegate

  func makeNSView(context: Context) -> WindowReader {
    let view = WindowReader()
    view.onWindow = { [weak delegate] window in delegate?.attachBoard(window) }
    return view
  }

  func updateNSView(_ view: WindowReader, context: Context) {}

  final class WindowReader: NSView {
    var onWindow: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { onWindow?(window) }
    }
  }
}
