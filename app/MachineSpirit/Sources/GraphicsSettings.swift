import SwiftUI

struct GraphicsSettings: View {
  @State private var expanded = false
  @State private var resetID = UUID()
  init(expanded: Bool = false) { _expanded = State(initialValue: expanded) }
  var body: some View {
    DisclosureGroup("Graphics", isExpanded: $expanded) {
      ScrollView {
        GraphicsControls().id(resetID)
        HStack {
          Text("Applies on next summon").foregroundStyle(.secondary)
          Spacer()
          Button("Reset to defaults") { OverlayFX.reset(); resetID = UUID() }
        }
      }
      .frame(maxHeight: 190)
      .padding(.top, 5)
    }
    .font(.system(.caption, design: .monospaced))
    .padding(.horizontal, 14).padding(.vertical, 5)
  }
}

private struct GraphicsControls: View {
  @AppStorage("msFX.accentHex") private var accentHex = "#36DE6A"
  @AppStorage("msFX.curvature") private var curvature = 0.4
  @AppStorage("msFX.randomness") private var randomness = 0.35
  @AppStorage("msFX.shake") private var shake = 0.4
  @AppStorage("msFX.glitch") private var glitch = 0.5
  private let flags = ["skull", "skullGlow", "letterPop", "shockwave", "miss", "back", "done", "hold", "close", "hover", "curvedTraces", "placementPreview", "hud", "capsFollower"]
  var body: some View {
    VStack(spacing: 7) {
      ColorPicker("Accent", selection: Binding(get: {
        Color(nsColor: OverlayFX.color(hex: accentHex) ?? OverlayFX.color(hex: "#36DE6A")!)
      }, set: { color in
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        accentHex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
          Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
      }), supportsOpacity: false)
      knob("Curvature", $curvature)
      knob("Randomness", $randomness)
      knob("Shake", $shake)
      knob("Glitch", $glitch)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 6) {
        ForEach(flags, id: \.self) { GraphicsFlag(name: $0) }
      }
    }
  }
  private func knob(_ title: String, _ value: Binding<Double>) -> some View {
    HStack {
      Text(title).frame(width: 86, alignment: .leading)
      Slider(value: value, in: 0...1)
      Text(value.wrappedValue, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 38)
    }
  }
}

private struct GraphicsFlag: View {
  let name: String
  @AppStorage private var enabled: Bool
  init(name: String) {
    self.name = name
    _enabled = AppStorage(wrappedValue: name != "curvedTraces", "msFX.\(name)")
  }
  private var label: String {
    ["skullGlow": "Skull glow", "letterPop": "Letter pop", "curvedTraces": "Curved traces",
     "placementPreview": "Placement preview", "hud": "HUD", "capsFollower": "Caps pointer badge"][name] ?? name.capitalized
  }
  var body: some View { Toggle(label, isOn: $enabled).toggleStyle(.checkbox) }
}
