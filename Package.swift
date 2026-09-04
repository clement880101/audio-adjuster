// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioAdjuster",
    platforms: [.macOS("14.2")],
    targets: [
        .target(
            name: "AudioAdjusterKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AudioAdjusterApp",
            dependencies: ["AudioAdjusterKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AudioAdjusterProbe",
            dependencies: ["AudioAdjusterKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AudioAdjusterKitTests",
            dependencies: ["AudioAdjusterKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
