// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "tegi",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TegiCore"),
        .executableTarget(name: "tegi", dependencies: ["TegiCore"]),
        .testTarget(name: "TegiCoreTests", dependencies: ["TegiCore"]),
    ],
    swiftLanguageModes: [.v5]
)
