import AppKit
import SwiftTerm
import SwiftUI

/// The sheol ledger, embedded: the SAME TUI (`bin/tmux-sheol.sh`) running in
/// a real terminal emulator inside the app. Commune, revive, the ◆◆◇ ward —
/// all of it works, because it's just a pty. Pop-out hands the ledger to
/// iTerm (tmux means the spirits don't care which body the client wears).
struct LedgerPane: View {
  @Environment(AppState.self) private var state

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("⌁ sheol")
          .font(.system(.caption, design: .monospaced).weight(.bold))
          .foregroundStyle(Theme.magenta)
        Spacer()
        Button {
          LedgerTerminal.endTUI()
          SheolService.openLedger()
          state.ledgerOpen = false
        } label: {
          Label("pop out", systemImage: "arrow.up.right.square")
            .font(.system(.caption, design: .monospaced))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ash)
        .help("hand the ledger to iTerm — the spirits don't mind changing bodies")
        Button {
          LedgerTerminal.endTUI()
          state.ledgerOpen = false
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ash)
        .help("close the ledger")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 5)
      .background(Theme.groundRaised.opacity(0.9))
      LedgerTerminal()
    }
    .background(Theme.ground)
  }
}

/// AppKit bridge to SwiftTerm's local-process terminal, themed to the board.
struct LedgerTerminal: NSViewRepresentable {
  func makeNSView(context: Context) -> LocalProcessTerminalView {
    let terminal = LocalProcessTerminalView(frame: .zero)
    terminal.nativeBackgroundColor = NSColor(Theme.ground)
    terminal.nativeForegroundColor = NSColor(Theme.phosphor)
    terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    terminal.startProcess(
      executable: "/bin/bash",
      args: [SheolService.helperPath("tmux-sheol.sh")],
      environment: nil,
      execName: nil)
    return terminal
  }

  func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

  /// The TUI's own single-instance doctrine, applied from the app side:
  /// its INT/TERM trap exits cleanly (SESSION-LOG war story made sure).
  static func endTUI() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    process.arguments = ["-f", "bin/tmux-sheol.sh"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
  }
}
