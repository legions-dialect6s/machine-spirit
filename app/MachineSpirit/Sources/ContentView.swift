import MachineSpiritKit
import SwiftUI

struct ContentView: View {
  @Environment(AppState.self) private var state

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(Theme.phosphorDim.opacity(0.4))
      main
      Divider().overlay(Theme.phosphorDim.opacity(0.4))
      footer
    }
    .background(Theme.ground)
    .frame(minWidth: 720, minHeight: 520)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Text("+++ machine-spirit +++")
        .font(.system(.title3, design: .monospaced).weight(.bold))
        .foregroundStyle(Theme.phosphor)
      Button {
        state.viewMode = state.viewMode == .tree ? .graph : .tree
      } label: {
        Text(state.viewMode == .tree ? "the witness" : "the altar")
          .font(.system(.callout, design: .monospaced))
          .foregroundStyle(state.viewMode == .tree ? Theme.ash : Theme.magenta)
      }
      .buttonStyle(.plain)
      .help("cross between worlds — tree ⇄ graph")
      Spacer()
      Button {
        state.communeWithLiveConfig()
      } label: {
        Label("commune again", systemImage: "arrow.trianglehead.2.clockwise")
          .font(.system(.callout, design: .monospaced))
      }
      .buttonStyle(.plain)
      .foregroundStyle(Theme.phosphorDim)
      .keyboardShortcut("r", modifiers: .command)
      .help("re-import the live Leader Key config (read-only) — ⌘R")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  @ViewBuilder private var main: some View {
    if let error = state.importError {
      VStack(spacing: 8) {
        Text("⚠ the communion failed")
          .font(.system(.headline, design: .monospaced))
          .foregroundStyle(Theme.magenta)
        Text(error)
          .font(.system(.callout, design: .monospaced))
          .foregroundStyle(Theme.ash)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if state.model != nil {
      switch state.viewMode {
      case .tree: TreeView()
      case .graph: GraphView()
      }
    } else {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var footer: some View {
    HStack {
      Text("\((state.displayModel?.totalCount ?? 1) - 1) nodes · imported live · read-only")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(Theme.ash)
      let wanderers = state.spirits.filter(\.isWandering).count
      Text(wanderers > 0 ? "⌁ \(wanderers) spirit\(wanderers == 1 ? "" : "s") wander sheol" : "⌁ sheol is empty")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(wanderers > 0 ? Theme.magenta : Theme.ash.opacity(0.6))
      Spacer()
      Text("⌥-click a triangle to unfold a whole branch")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(Theme.ash.opacity(0.7))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
  }
}
