// Tests/Standalone/YabaiEnvironmentProfileTests.swift
// 确定性边界验证：yabai 环境探测与布局判定
// Mirrors: Sources/Support/YabaiEnvironmentProbe.swift
// 背景: docs/window-capability-matrix.md —— yabai 是可选增强；v7 float 布局下
//       `window --space` 静默失效（2026-09-01 toggle 跨屏失效事故），空间命令的
//       可信性必须由环境 profile 决定，禁止"存在即可用"假设。
// Run: swift Tests/Standalone/YabaiEnvironmentProfileTests.swift

import Foundation

// MARK: - 镜像实现（源: Sources/Support/YabaiEnvironmentProbe.swift）

struct YabaiSpaceLayout: Equatable {
    let index: Int
    let display: Int
    let layout: String
}

struct YabaiEnvironmentProfile: Equatable {
    let binaryPresent: Bool
    let binaryPath: String?
    let daemonResponsive: Bool
    let versionString: String?
    let spaces: [YabaiSpaceLayout]

    var usableAsEnhancer: Bool { binaryPresent && daemonResponsive }

    var isAllFloatLayout: Bool {
        !spaces.isEmpty && spaces.allSatisfy { $0.layout == "float" }
    }

    var hasBSPSpace: Bool {
        spaces.contains { $0.layout == "bsp" }
    }

    var spaceMoveTrusted: Bool {
        daemonResponsive && !spaces.isEmpty && !spaces.contains { $0.layout == "float" }
    }
}

enum YabaiEnvironmentProbe {
    static let candidatePaths = [
        "/opt/homebrew/bin/yabai",
        "/usr/local/bin/yabai",
        "/usr/bin/yabai"
    ]

    static func locateBinary(fileExists: (String) -> Bool) -> String? {
        candidatePaths.first { fileExists($0) }
    }

    static func probe(
        runner: (String, [String]) -> (exitCode: Int32, stdout: String)?,
        fileExists: (String) -> Bool,
        timeoutSeconds: TimeInterval = 2.0
    ) -> YabaiEnvironmentProfile {
        guard let binaryPath = locateBinary(fileExists: fileExists) else {
            return YabaiEnvironmentProfile(
                binaryPresent: false, binaryPath: nil,
                daemonResponsive: false, versionString: nil, spaces: []
            )
        }
        guard let spacesResult = runner(binaryPath, ["-m", "query", "--spaces"]),
              spacesResult.exitCode == 0 else {
            return YabaiEnvironmentProfile(
                binaryPresent: true, binaryPath: binaryPath,
                daemonResponsive: false, versionString: nil, spaces: []
            )
        }
        let version = runner(binaryPath, ["--version"]).map { $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        return YabaiEnvironmentProfile(
            binaryPresent: true,
            binaryPath: binaryPath,
            daemonResponsive: true,
            versionString: version,
            spaces: parseSpaces(spacesResult.stdout)
        )
    }

    static func parseSpaces(_ json: String) -> [YabaiSpaceLayout] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { dict in
            guard let index = dict["index"] as? Int,
                  let display = dict["display"] as? Int else { return nil }
            return YabaiSpaceLayout(
                index: index,
                display: display,
                layout: dict["type"] as? String ?? "unknown"
            )
        }
    }

}

// MARK: - 断言框架

var failures: [String] = []
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    print("[\(condition ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : "  -- \(detail)")")
    if !condition { failures.append(name) }
}

// MARK: - 真实环境 JSON 样例（取自本机 yabai v7.1.18，float 全布局）

let floatLayoutJSON = """
[{
\t"id":5,
\t"uuid":"7C2B0492-E114-459C-B26C-A4C7A6F9FE9A",
\t"index":1,
\t"label":"",
\t"type":"float",
\t"display":1,
\t"windows":[140, 141],
\t"has-focus":true,
\t"is-visible":true
},{
\t"id":325,
\t"index":2,
\t"label":"",
\t"type":"float",
\t"display":2,
\t"windows":[360],
\t"has-focus":false,
\t"is-visible":false
}]
"""

let bspLayoutJSON = """
[{"index":1,"type":"bsp","display":1},{"index":2,"type":"bsp","display":2}]
"""

let mixedLayoutJSON = """
[{"index":1,"type":"float","display":1},{"index":2,"type":"bsp","display":2}]
"""

// MARK: - parseSpaces 边界

let floatSpaces = YabaiEnvironmentProbe.parseSpaces(floatLayoutJSON)
check("S1 float 全布局解析出 2 个 space", floatSpaces.count == 2)
check("S2 float 全布局 → isAllFloatLayout=true", YabaiEnvironmentProfile(
    binaryPresent: true, binaryPath: "/opt/homebrew/bin/yabai",
    daemonResponsive: true, versionString: "yabai-v7.1.18", spaces: floatSpaces
).isAllFloatLayout)
check("S3 float 全布局 → spaceMoveTrusted=false（--space 不可信）", !YabaiEnvironmentProfile(
    binaryPresent: true, binaryPath: "/x", daemonResponsive: true,
    versionString: nil, spaces: floatSpaces
).spaceMoveTrusted)

let bspSpaces = YabaiEnvironmentProbe.parseSpaces(bspLayoutJSON)
check("S4 bsp 全布局 → hasBSPSpace 且 spaceMoveTrusted=true", YabaiEnvironmentProfile(
    binaryPresent: true, binaryPath: "/x", daemonResponsive: true,
    versionString: nil, spaces: bspSpaces
).spaceMoveTrusted)

let mixedSpaces = YabaiEnvironmentProbe.parseSpaces(mixedLayoutJSON)
check("S5 混合布局 → spaceMoveTrusted=false（保守策略）", !YabaiEnvironmentProfile(
    binaryPresent: true, binaryPath: "/x", daemonResponsive: true,
    versionString: nil, spaces: mixedSpaces
).spaceMoveTrusted)

check("S6 空 space 列表 → isAllFloatLayout=false（guard 非空）", !YabaiEnvironmentProfile(
    binaryPresent: true, binaryPath: "/x", daemonResponsive: true,
    versionString: nil, spaces: []
).isAllFloatLayout)

check("S7 坏 JSON → 空数组", YabaiEnvironmentProbe.parseSpaces("not-json{").isEmpty)

let missingType = YabaiEnvironmentProbe.parseSpaces("[{\"index\":1,\"display\":1}]")
check("S8 缺 type 字段 → layout 兜底 unknown", missingType.count == 1 && missingType[0].layout == "unknown")

let missingIndex = YabaiEnvironmentProbe.parseSpaces("[{\"display\":1,\"type\":\"float\"},{\"index\":2,\"display\":1,\"type\":\"bsp\"}]")
check("S9 缺 index/display 的条目被跳过，其余保留", missingIndex.count == 1 && missingIndex[0].index == 2)

// MARK: - probe 三层判定（runner 注入，零真实 I/O）

// P1: L1 失败——二进制不存在
let p1 = YabaiEnvironmentProbe.probe(
    runner: { _, _ in (0, "[]") },
    fileExists: { _ in false }
)
check("P1 二进制不存在 → 不可用作增强", !p1.usableAsEnhancer && p1.binaryPath == nil)

// P2: L2 失败——daemon 无响应（fork 失败）
let p2 = YabaiEnvironmentProbe.probe(
    runner: { _, _ in nil },
    fileExists: { $0 == "/opt/homebrew/bin/yabai" }
)
check("P2 daemon fork 失败 → binaryPresent 但不可用", p2.binaryPresent && !p2.usableAsEnhancer && p2.spaces.isEmpty)

// P3: L2 失败——命令非零退出
let p3 = YabaiEnvironmentProbe.probe(
    runner: { path, args in (1, "") },
    fileExists: { _ in true }
)
check("P3 daemon 非零退出 → 不可用", p3.binaryPresent && !p3.daemonResponsive && !p3.usableAsEnhancer)

// P4: 全通过 + float 布局 → 可用但 --space 不可信
var p4Calls: [String] = []
let p4 = YabaiEnvironmentProbe.probe(
    runner: { path, args in
        p4Calls.append(args.joined(separator: " "))
        return args.first == "--version" ? (0, "yabai-v7.1.18\n") : (0, floatLayoutJSON)
    },
    fileExists: { _ in true }
)
check("P4 L1+L2 通过 → 可用作增强", p4.usableAsEnhancer)
check("P5 float 布局 → spaceMoveTrusted=false", !p4.spaceMoveTrusted)
check("P6 版本采集成功", p4.versionString == "yabai-v7.1.18")
check("P7 探测命令集最小化（query --spaces + --version）", p4Calls.count == 2)

// P8: 全通过 + bsp 布局 → --space 可信
let p8 = YabaiEnvironmentProbe.probe(
    runner: { _, args in args.first == "--version" ? (0, "yabai-v6.0.1\n") : (0, bspLayoutJSON) },
    fileExists: { _ in true }
)
check("P8 bsp 布局 → spaceMoveTrusted=true", p8.spaceMoveTrusted)

// MARK: - L1 路径优先级

let firstHit = YabaiEnvironmentProbe.locateBinary(fileExists: { $0 == "/usr/local/bin/yabai" })
check("L1 候选路径按序命中", firstHit == "/usr/local/bin/yabai")

print("\n========================================")
if failures.isEmpty {
    print("结果: 全部 PASS — yabai 环境判定边界已固化")
} else {
    print("结果: \(failures.count) 项失败: \(failures.joined(separator: ", "))")
}
exit(failures.isEmpty ? 0 : 1)
