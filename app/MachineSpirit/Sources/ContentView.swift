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
    .frame(minWidth: 1100, minHeight: 620)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Text("+++ machine-spirit +++")
        .font(.system(.title3, design: .monospaced).weight(.bold))
        .foregroundStyle(Theme.phosphor)
      Spacer()
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
      .help("re-import the live Leader Key config (read-only) — ⌘R")
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
      HSplitView {
        pane(.directory, title: "directory") { TreeView() }
          .frame(minWidth: 340, idealWidth: 460, maxWidth: 720)
        pane(.graph, title: "node graph") { GraphView() }
          .frame(minWidth: 480, maxWidth: .infinity)
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
      Text("\((state.displayModel?.totalCount ?? 1) - 1) nodes · imported live · read-only")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(Theme.ash)
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
