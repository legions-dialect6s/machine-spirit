import MachineSpiritKit
import SwiftUI

/// The pen's add form: one leaf bind, inscribed under the aimed group
/// through ConfigWriter's full ritual (gate → backup → validate → atomic
/// swap). Deliberately small — key, optional label, action type, value.
/// Groups-in-groups and edit-in-place are later strokes of the same pen.
struct AddBindForm: View {
  @Environment(AppState.self) private var state
  @Environment(\.dismiss) private var dismiss

  @State private var key = ""
  @State private var label = ""
  @State private var type = "command"
  @State private var value = ""

  private static let types = ["command", "application", "url", "folder"]

  private static let placeholders: [String: String] = [
    "command": "~/bin/something.sh",
    "application": "/Applications/Name.app",
    "url": "https://…",
    "folder": "~/projects",
  ]

  private var targetID: String { state.penTargetGroupID ?? "root" }

  /// Human path of the aimed group: `root/g/p` → `g p` in key glyphs.
  private var targetPath: String {
    let keys = targetID.split(separator: "/").dropFirst()
    return keys.isEmpty ? "the root" : keys.joined(separator: " · ")
  }

  private var problem: String? {
    if key.isEmpty { return "a bind needs a key" }
    if key.count > 1 { return "one key — a single character" }
    if key == "/" { return "'/' would break structural ids" }
    if let group = state.displayModel?.node(withID: targetID),
      group.children.contains(where: { $0.key == key })
    {
      return "'\(key)' is already bound under \(targetPath)"
    }
    if value.trimmingCharacters(in: .whitespaces).isEmpty { return "a bind needs a value" }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("inscribe a bind under \(targetPath)")
        .font(.system(.callout, design: .monospaced).weight(.bold))
        .foregroundStyle(Theme.phosphor)

      HStack(spacing: 8) {
        field("key", text: $key, prompt: "n", width: 44)
        field("label (optional)", text: $label, prompt: "what it does")
      }

      HStack(spacing: 8) {
        Picker("", selection: $type) {
          ForEach(Self.types, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 118)
        field("value", text: $value, prompt: Self.placeholders[type] ?? "")
          .onSubmit { submit() }
      }

      HStack {
        Text(problem ?? "writes the live config — gate, backup, atomic swap")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(problem == nil ? Theme.ash.opacity(0.7) : Theme.magenta.opacity(0.9))
        Spacer()
        Button("cancel") { dismiss() }
          .buttonStyle(.plain)
          .foregroundStyle(Theme.ash)
        Button("inscribe") { submit() }
          .buttonStyle(.plain)
          .foregroundStyle(problem == nil ? Theme.phosphor : Theme.ash.opacity(0.4))
          .disabled(problem != nil)
          .keyboardShortcut(.defaultAction)
      }
      .font(.system(.callout, design: .monospaced))
    }
    .padding(14)
    .frame(width: 460)
    .background(Theme.ground)
  }

  private func submit() {
    guard problem == nil else { return }
    state.penAdd(key: key, label: label.isEmpty ? nil : label, type: type, value: value)
    dismiss()
  }

  private func field(
    _ title: String, text: Binding<String>, prompt: String, width: CGFloat? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(Theme.ash.opacity(0.8))
      TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.ash.opacity(0.45)))
        .textFieldStyle(.plain)
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(Theme.phosphor)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Theme.groundRaised.opacity(0.8))
        .overlay(Rectangle().strokeBorder(Theme.phosphorDim.opacity(0.35), lineWidth: 1))
    }
    .frame(width: width)
  }
}
