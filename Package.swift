// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeRecall",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeRecall",
            path: "Sources/ClaudeRecall"
        )
    ]
)
