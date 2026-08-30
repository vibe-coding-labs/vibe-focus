// swift-tools-version:5.9
import PackageDescription

// 性能埋点开关（Phase 7，2026-08-31）：
// P-INST 埋点样板已用 #if PERF_INSTRUMENT 包裹（约 100+ 处，工具脚本
// scripts/condense-perf-instrumentation.py / condense-perf-elapsed.py 生成）。
// 默认关闭（零埋点开销）；需要性能归因时用以下命令启用：
//   swift build -Xswiftc -DPERF_INSTRUMENT
// 编排函数中耗时字段外泄进日志字典的埋点（MoveWindow/Toggle 等）未包裹，始终生效。

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
                "VibeFocusKit"
            ],
            path: "Tests/XCTest"
        )
    ]
)
