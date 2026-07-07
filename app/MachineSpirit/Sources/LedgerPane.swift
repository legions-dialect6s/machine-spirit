import AppKit
import Darwin
import SwiftTerm
import SwiftUI

/// The sheol ledger, embedded: the SAME TUI (`bin/tmux-sheol.sh`) running in
/// a real terminal emulator inside the app. Commune, revive, the ◆◆◇ ward —
/// all of it works, because it's just a pty. Pop-out hands the ledger to
/// iTerm (tmux means the spirits don't care which body the client wears).
struct LedgerPane: View {
  @Environment(AppState.self) private var state

  var body: some View {
    let focused = state.focusedPane == .ledger
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("⌁ sheol")
          .font(.system(.caption, design: .monospaced).weight(focused ? .bold : .regular))
          .foregroundStyle(Theme.magenta)
        if focused {
          Circle().fill(Theme.magenta).frame(width: 5, height: 5)
        }
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
      .background(Theme.groundRaised.opacity(focused ? 0.95 : 0.5))
      LedgerTerminal()
    }
    .background(Theme.ground)
    .overlay(
      Rectangle()
        .strokeBorder(focused ? Theme.magenta.opacity(0.5) : Color.clear, lineWidth: 1)
    )
    .contentShape(Rectangle())
    .simultaneousGesture(TapGesture().onEnded { state.focusedPane = .ledger })
    .onChange(of: state.focusedPane) {
      if state.focusedPane == .ledger { LedgerTerminal.claimKeyboard() }
    }
    .onAppear {
      state.focusedPane = .ledger
      LedgerTerminal.claimKeyboard()
    }
    .onDisappear {
      if state.focusedPane == .ledger { state.focusedPane = .graph }
    }
  }
}

/// AppKit bridge to SwiftTerm's local-process terminal, wearing the
/// owner's actual iTerm colors (parsed from the repo's .itermcolors) and a
/// real PATH — GUI apps inherit a bare one, which is why tmux "wasn't
/// installed" from inside the pane.
struct LedgerTerminal: NSViewRepresentable {
  /// The live terminal view, so pane focus can hand it the keyboard.
  @MainActor static weak var current: LocalProcessTerminalView?

  static func claimKeyboard() {
    DispatchQueue.main.async {
      guard let terminal = current else { return }
      terminal.window?.makeFirstResponder(terminal)
    }
  }

  func makeNSView(context: Context) -> LocalProcessTerminalView {
    let terminal = LocalProcessTerminalView(frame: .zero)
    Self.current = terminal
    ITermColors.apply(to: terminal)
    terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let environment = [
      "TERM=xterm-256color",
      "LANG=en_US.UTF-8",
      "HOME=\(home)",
      "USER=\(NSUserName())",
      "SHELL=/bin/zsh",
      "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    ]
    terminal.startProcess(
      executable: "/bin/bash",
      args: [SheolService.helperPath("tmux-sheol.sh")],
      environment: environment,
      execName: nil)
    return terminal
  }

  func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

  /// The TUI's own single-instance doctrine, applied from the app side:
  /// prefer the pidfile that tmux-sheol writes; broad pkill is only a stale-file fallback.
  static func endTUI() {
    let pidfile = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".cache/machine-spirit/sheol.pid")
    if let text = try? String(contentsOf: pidfile, encoding: .utf8),
      let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
      commandLine(for: pid).contains("tmux-sheol.sh")
    {
      kill(pid, SIGTERM)
      return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    process.arguments = ["-f", "bin/tmux-sheol.sh"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
  }

  private static func commandLine(for pid: Int32) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", String(pid), "-o", "command="]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return String(data: data, encoding: .utf8) ?? ""
    } catch {
      return ""
    }
  }
}
