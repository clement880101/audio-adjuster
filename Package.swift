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
        // Drawing only, and no dependency on AudioAdjusterKit: the audio engine has no
        // business knowing what the logo looks like. Shared by the app (menu bar glyph)
        // and BrandMarkRender (the .icns ladder).
        .target(
            name: "BrandMark",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AudioAdjusterApp",
            dependencies: ["AudioAdjusterKit", "BrandMark"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AudioAdjusterProbe",
            dependencies: ["AudioAdjusterKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BrandMarkRender",
            dependencies: ["BrandMark"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AudioAdjusterKitTests",
            dependencies: ["AudioAdjusterKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BrandMarkTests",
            dependencies: ["BrandMark"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
