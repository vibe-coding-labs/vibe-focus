// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "vibe-focus-hotkeys",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VibeFocusHotkeys", targets: ["VibeFocusHotkeys"])
    ],
    dependencies: [
        .package(url: "https://github.com/yene/GCDWebServer", from: "3.5.4")
    ],
    targets: [
        .systemLibrary(name: "Csqlite3", path: "Csqlite3"),
        .executableTarget(
            name: "VibeFocusHotkeys",
            dependencies: [
                .product(name: "GCDWebServer", package: "GCDWebServer"),
                .target(name: "Csqlite3")
            ],
            path: "Sources",
            exclude: [],
            resources: [
                .copy("../Resources/yabai-space-changed.sh"),
                .copy("../Resources/claude-session-hook-example.sh"),
                .copy("../Resources/Sounds")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
