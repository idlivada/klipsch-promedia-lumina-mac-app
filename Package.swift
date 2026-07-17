// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LuminaMac",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LuminaProtocol"),
        .executableTarget(name: "probe", dependencies: ["LuminaProtocol"]),
        .executableTarget(name: "LuminaBar", dependencies: ["LuminaProtocol"]),
    ]
)
