// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Objective",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Objective",
            path: "Sources/Objective",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
