// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Clipsight",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Clipsight"),
    ],
    swiftLanguageModes: [.v5]
)
