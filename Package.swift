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
        .package(url: "https://github.com/yene/GCDWebServer", from: "3.5.4"),
        .package(url: "https://github.com/apple/swift-testing", from: "0.7.0")
    ],
    targets: [
        .systemLibrary(name: "Csqlite3", path: "Csqlite3"),
        .target(
            name: "VibeFocusKit",
            dependencies: [
                .product(name: "GCDWebServer", package: "GCDWebServer"),
                .target(name: "Csqlite3")
            ],
            path: "Sources",
            exclude: ["AppEntry"],
            resources: [
                .copy("../Resources/yabai-space-changed.sh"),
                .copy("../Resources/claude-session-hook-example.sh"),
                .copy("../Resources/Sounds")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "VibeFocusHotkeys",
            dependencies: ["VibeFocusKit"],
            path: "Sources/AppEntry"
        ),
        .testTarget(
            name: "VibeFocusTests",
            dependencies: [
                "VibeFocusKit",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/XCTest"
        )
    ]
)
