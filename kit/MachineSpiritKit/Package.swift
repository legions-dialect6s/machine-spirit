// swift-tools-version: 6.0
// MachineSpiritKit — the spine of the machine-spirit app.
// UI-free by law: no AppKit/SwiftUI imports anywhere in Sources/.
// `swift test` runs headless; the round-trip gate lives in Tests/.
import PackageDescription

let package = Package(
  name: "MachineSpiritKit",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "MachineSpiritKit", targets: ["MachineSpiritKit"])
  ],
  targets: [
    .target(name: "MachineSpiritKit"),
    .testTarget(
      name: "MachineSpiritKitTests",
      dependencies: ["MachineSpiritKit"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
