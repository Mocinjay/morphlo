// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Morphlo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Morphlo",
            path: "Sources/Morphlo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
