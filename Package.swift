// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LlmTokenWidget",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LlmTokenWidget",
            path: "Sources/LlmTokenWidget"
        )
    ]
)
