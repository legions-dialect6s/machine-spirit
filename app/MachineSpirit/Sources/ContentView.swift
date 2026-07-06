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
      Text(state.viewMode == .tree ? "the witness" : "the altar")
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(Theme.ash)
      Spacer()
      Button {
        state.communeWithLiveConfig()
      } label: {
        Label("commune again", systemImage: "arrow.trianglehead.2.clockwise")
          .font(.system(.callout, design: .monospaced))
      }
      .buttonStyle(.plain)
      .foregroundStyle(Theme.phosphorDim)
      .help("re-import the live Leader Key config (read-only)")
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
      case .graph: TreeView()  // the altar arrives in [P1.5]
      }
    } else {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var footer: some View {
    HStack {
      Text("\(state.nodeCount) nodes · imported live · read-only")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(Theme.ash)
      Spacer()
      Text("⌥-click a triangle to unfold a whole branch")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(Theme.ash.opacity(0.7))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
  }
}
