// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FSearch",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FSearch",
            resources: [.process("Resources")]
        )
    ]
)
