// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ms",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ms", targets: ["ms"])],
    targets: [
        .executableTarget(name: "ms"),
        .testTarget(name: "msTests", dependencies: ["ms"]),
    ]
)
