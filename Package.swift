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
        // 真实代码测试运行器（2026-09-02，CLT-only 环境的 swift test 过渡通道）：
        // CLT 无 XCTest/Swift Testing 运行时，Tests/XCTest 套件无法在本机执行。
        // 本执行器 @testable import VibeFocusKit（debug 自带 -enable-testing）直测
        // internal 逻辑（无 Standalone 镜像漂移）；覆盖率用
        // swift build -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping
        // + llvm-profdata/llvm-cov 产出真实数字（scripts/coverage_test_runner.sh）。
        .executableTarget(
            name: "VibeFocusTestRunner",
            dependencies: ["VibeFocusKit"],
            path: "Tests/Runner",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
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
