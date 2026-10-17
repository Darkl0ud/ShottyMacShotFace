// swift-tools-version:6.0
// Tools 6.0 is needed for swift-testing's macros to load under the Command Line Tools.
// The Swift 5 language mode (below) keeps AppKit/ScreenCaptureKit callbacks from drowning in
// Swift 6 strict-concurrency errors.
import PackageDescription

let package = Package(
    name: "ShottyMacShotFace",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ShottyMacShotFace", targets: ["ShottyMacShotFace"]),
    ],
    targets: [
        // Everything that can be tested without a screen: model, rendering, effects, settings.
        .target(name: "ShottyCore", path: "Sources/ShottyCore"),
        // The menu-bar app: capture, overlays, editor window, preferences.
        .executableTarget(
            name: "ShottyMacShotFace",
            dependencies: ["ShottyCore"],
            path: "Sources/ShottyMacShotFace"
        ),
        .testTarget(
            name: "ShottyCoreTests",
            dependencies: ["ShottyCore"],
            path: "Tests/ShottyCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
