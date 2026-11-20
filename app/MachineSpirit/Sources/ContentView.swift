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
      GeometryReader { geometry in header(compact: geometry.size.width < 640) }
        .frame(height: 44)
      Divider().overlay(Theme.phosphorDim.opacity(0.4))
      main
      Divider().overlay(Theme.phosphorDim.opacity(0.4))
      GraphicsSettings()
      statsSection
      footer
    }
    .background(Theme.ground)
    .frame(minWidth: 420)
    .onAppear { typeTitle() }
    .onDisappear { typingTask?.cancel() }
    .onChange(of: state.bootStamp) { typeTitle() }
  }

  private func header(compact: Bool) -> some View {
    ZStack {
      if !compact {
        // The wordmark holds the center of the machine.
        ZStack(alignment: .leading) {
          Text(Self.fullTitle).hidden()  // reserve the full width
          Text(typedTitle)
        }
        .font(.system(.title3, design: .monospaced).weight(.bold))
        .foregroundStyle(Theme.phosphor)
      }

      HStack(spacing: 10) {
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
            state.refreshFlashing ? "✓ refreshed" : "refresh",
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
    .lineLimit(1)
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
      // Keep one split hierarchy at every width so resizing cannot recreate
      // the embedded terminal. Both panes can fit inside a 420pt board.
      HSplitView {
        pane(.graph, title: "node graph") { GraphView() }
          .frame(minWidth: 160, maxWidth: .infinity)
        if state.ledgerOpen {
          LedgerPane().frame(minWidth: 220, idealWidth: 380)
        }
      }
    } else {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// The focused graph wears the brighter rail beside the optional ledger.
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

  @ViewBuilder private var statsSection: some View {
    if state.stats.enabled {
      let stats = state.stats.snapshot
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("local · \(stats.totalFires) fires · \(stats.perDay[BindStats.day(Date()), default: 0]) today · ~\(stats.timeSavedLabel) saved")
          Spacer()
          Button("Reset stats") { state.stats.reset() }
          Button("Disable") { state.stats.disable() }
        }
        Text(stats.topPaths.prefix(5).map { "\($0.key) ×\($0.value)" }.joined(separator: "  ·  "))
          .lineLimit(1).truncationMode(.tail)
        if let error = state.stats.persistenceError { Text(error).foregroundStyle(Theme.magenta) }
      }
      .font(.system(.caption, design: .monospaced))
      .foregroundStyle(Theme.ash)
      .padding(.horizontal, 14).padding(.vertical, 6)
    }
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
    .lineLimit(1)
    .truncationMode(.tail)
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
  }
}
