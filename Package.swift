// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FloatPlayer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FloatPlayer",
            path: "Sources/FloatPlayer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
