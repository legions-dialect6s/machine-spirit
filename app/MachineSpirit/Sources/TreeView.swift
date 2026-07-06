import MachineSpiritKit
import SwiftUI

/// The witness: the imported config as a directory tree, node for node
/// beside Leader Key's reality. Read-only.
///
/// Disclosure state lives in AppState (`expandedIDs`) so landing from the
/// altar can unfold the path to the selection and scroll to it.
struct TreeView: View {
  @Environment(AppState.self) private var state

  var body: some View {
    @Bindable var state = state
    ScrollViewReader { proxy in
      List(selection: $state.selectedNodeID) {
        if let model = state.model {
          ForEach(model.children) { child in
            NodeBranch(node: child)
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(Theme.ground)
      .environment(\.defaultMinListRowHeight, 26)
      .onAppear {
        state.revealSelectionInTree()
        if let id = state.selectedNodeID {
          // Let the freshly-expanded rows lay out before scrolling.
          DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
          }
        }
      }
    }
  }
}

private struct NodeBranch: View {
  @Environment(AppState.self) private var state
  let node: Node

  var body: some View {
    @Bindable var state = state
    if node.children.isEmpty {
      NodeRow(node: node)
        .tag(node.id)
        .id(node.id)
        .listRowBackground(Color.clear)
    } else {
      DisclosureGroup(
        isExpanded: Binding(
          get: { state.expandedIDs.contains(node.id) },
          set: { expanded in
            if expanded {
              state.expandedIDs.insert(node.id)
            } else {
              state.expandedIDs.remove(node.id)
            }
          }
        )
      ) {
        ForEach(node.children) { child in
          NodeBranch(node: child)
        }
      } label: {
        NodeRow(node: node)
          .tag(node.id)
          .id(node.id)
      }
      .listRowBackground(Color.clear)
    }
  }
}

struct NodeRow: View {
  let node: Node

  var body: some View {
    HStack(spacing: 10) {
      Text(node.key ?? "·")
        .font(.system(.body, design: .monospaced).weight(.bold))
        .foregroundStyle(node.status.isInert ? Theme.ash : Theme.phosphor)
        .frame(minWidth: 22)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(Theme.groundRaised)
            .strokeBorder(
              (node.status.isInert ? Theme.ash : Theme.phosphorDim).opacity(0.6),
              lineWidth: 1)
        )

      Text(Theme.badgeText(for: node))
        .font(.system(size: 9, design: .monospaced).weight(.semibold))
        .foregroundStyle(Theme.ground)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(Theme.badgeColor(for: node).opacity(node.status.isInert ? 0.4 : 1)))

      Text(node.displayName)
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(node.status.isInert ? Theme.ash : .primary)
        .lineLimit(1)

      if node.isDual {
        // Ring and core, both lit — a node that is group AND action.
        Image(systemName: "circle.circle.fill")
          .font(.system(size: 11))
          .foregroundStyle(Theme.magenta)
          .help("group AND action — ring and core, both lit")
      }

      Spacer()

      if let action = node.action {
        Text(action.windowAction.map { "⧉ \($0)" } ?? action.value)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(Theme.ash)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: 340, alignment: .trailing)
      } else {
        Text("\(node.children.count)")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(Theme.phosphorDim)
      }
    }
    .opacity(node.status.isInert ? 0.45 : 1)
    .help(node.status.inertReason.map { "inert — \($0)" } ?? node.action?.value ?? node.displayName)
  }
}
