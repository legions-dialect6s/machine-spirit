import MachineSpiritKit
import SwiftUI

struct ContentView: View {
  @Environment(AppState.self) private var state

  // The wordmark types itself in on boot and refresh — the same reveal
  // sheol's TUI plays. (Aesthetics become user parameters later — #29.)
  private static let fullTitle = "+++ machine-spirit +++"
  @State private var typedTitle = ""
  @State private var typingTask: Task<Void, Never>?

  private func typeTitle() {
    typingTask?.cancel()
    typedTitle = ""
    typingTask = Task {
      for character in Self.fullTitle {
        guard !Task.isCancelled else { return }
        typedTitle.append(character)
        try? await Task.sleep(for: .milliseconds(26))
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(Theme.phosphorDim.opacity(0.4))
      main
      Divider().overlay(Theme.phosphorDim.opacity(0.4))
      footer
    }
    .background(Theme.ground)
    .frame(minWidth: 1100, minHeight: 620)
    .onAppear { typeTitle() }
    .onChange(of: state.bootStamp) { typeTitle() }
  }

  private var header: some View {
    ZStack {
      // The wordmark holds the center of the machine.
      ZStack(alignment: .leading) {
        Text(Self.fullTitle).hidden()  // reserve the full width
        Text(typedTitle)
      }
      .font(.system(.title3, design: .monospaced).weight(.bold))
      .foregroundStyle(Theme.phosphor)

      HStack(spacing: 10) {
      Button {
        state.directoryCollapsed.toggle()
      } label: {
        Label(
          "directory", systemImage: state.directoryCollapsed ? "chevron.right" : "chevron.left"
        )
        .font(.system(.callout, design: .monospaced))
      }
      .buttonStyle(.plain)
      .foregroundStyle(state.directoryCollapsed ? Theme.ash : Theme.phosphorDim)
      .help(state.directoryCollapsed ? "show the directory" : "collapse the directory")
      Spacer()
      Button {
        if state.ledgerOpen {
          LedgerTerminal.endTUI()
          state.ledgerOpen = false
        } else {
          state.ledgerOpen = true
        }
      } label: {
        Label("sheol", systemImage: "moon.haze")
          .font(.system(.callout, design: .monospaced))
      }
      .buttonStyle(.plain)
      .foregroundStyle(state.ledgerOpen ? Theme.magenta : Theme.magenta.opacity(0.7))
      .help("the ledger, embedded — sheol stays a terminal; this just gives it a pane")
      Button {
        state.refresh()
      } label: {
        Label(
          state.refreshFlashing ? "✓ re-imported \((state.displayModel?.totalCount ?? 1) - 1) nodes" : "refresh",
          systemImage: "arrow.trianglehead.2.clockwise"
        )
        .font(.system(.callout, design: .monospaced))
      }
      .buttonStyle(.plain)
      .foregroundStyle(state.refreshFlashing ? Theme.phosphor : Theme.phosphorDim)
      .animation(.easeOut(duration: 0.2), value: state.refreshFlashing)
      .help("re-import the live Leader Key config — ⌘R")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  @ViewBuilder private var main: some View {
    if let error = state.importError {
      VStack(spacing: 8) {
        Text("⚠ import failed")
          .font(.system(.headline, design: .monospaced))
          .foregroundStyle(Theme.magenta)
        Text(error)
          .font(.system(.callout, design: .monospaced))
          .foregroundStyle(Theme.ash)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if state.model != nil {
      // The board gets the window; the directory opens at its narrowest and
      // collapses entirely (the header button brings it back).
      HSplitView {
        if !state.directoryCollapsed {
          pane(.directory, title: "directory") { TreeView() }
            .frame(minWidth: 260, idealWidth: 260, maxWidth: 560)
        }
        // The huge ideal width makes HSplitView actually honor the
        // directory's narrow ideal on first layout — the board is the star.
        pane(.graph, title: "node graph") { GraphView() }
          .frame(minWidth: 480, idealWidth: 4000, maxWidth: .infinity)
        if state.ledgerOpen {
          LedgerPane()
            .frame(minWidth: 380, idealWidth: 440, maxWidth: 640)
        }
      }
    } else {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// Both projections stay visible; the focused one wears the brighter rail.
  private func pane<Content: View>(
    _ pane: FocusedPane, title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    let focused = state.focusedPane == pane
    return VStack(spacing: 0) {
      HStack {
        Text(title)
          .font(.system(.caption, design: .monospaced).weight(focused ? .bold : .regular))
          .foregroundStyle(focused ? Theme.phosphor : Theme.ash)
        if focused {
          Circle().fill(Theme.phosphor).frame(width: 5, height: 5)
        }
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 5)
      .background(Theme.groundRaised.opacity(focused ? 0.9 : 0.4))
      content()
    }
    .overlay(
      Rectangle()
        .strokeBorder(
          focused ? Theme.phosphorDim.opacity(0.7) : Color.clear, lineWidth: 1)
    )
    .contentShape(Rectangle())
    .simultaneousGesture(TapGesture().onEnded { state.focusedPane = pane })
  }

  private var footer: some View {
    HStack {
      Text("\((state.displayModel?.totalCount ?? 1) - 1) nodes · imported live · pen wired")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(Theme.ash)
      // The pen speaks here: node-level summary of the last live write,
      // or exactly why one was refused. Both fade on their own.
      if let error = state.penError {
        Text("✎ \(error)")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(Theme.magenta)
          .lineLimit(1)
          .help(error)
      } else if let mark = state.penMark {
        Text("✎ \(mark.lines.joined(separator: " · ")) · backup kept")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(Theme.phosphor)
          .help("backup: \(mark.backupPath)")
      }
      let wanderers = state.spirits.filter(\.isWandering).count
      Text(wanderers > 0 ? "⌁ \(wanderers) spirit\(wanderers == 1 ? "" : "s") wander sheol" : "⌁ sheol is empty")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(wanderers > 0 ? Theme.magenta : Theme.ash.opacity(0.6))
      Spacer()
      Text("type keys to walk · esc root · ⌫ up · ⌘R refresh")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(Theme.ash.opacity(0.7))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
  }
}
