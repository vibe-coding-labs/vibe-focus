// Tests/Standalone/ArchitectureConformanceTests.swift
// Verification: 架构单出口不变量守护（Batch 9）——把重构批次建立的唯一出口契约
//              变成 run_all_tests 里的机械断言，新会话手抄副本会在门禁当场爆掉。
// Mirrors:     无运行时逻辑——静态扫描 Sources/**/*.swift 代码行（跳过注释行），
//              每条规则 = 「禁止模式 + 合法消费文件白名单」。
//              白名单即消费方清单：新增合法出口必须显式改本文件的允许列表，
//              让「谁在绕过唯一出口」在 code review 的 diff 里可见。
// Run:         swift Tests/Standalone/ArchitectureConformanceTests.swift
//
// ## 规则与出处
// R1  waitForRelayout(            只许 FrameConvergence（骨架定义）/ FloatSettle（唯一调用方）
//                                 调用——Batch 6 前四处手抄 + restore 固定 sleep 的漂移即教训。
// R2  floatRelayoutSettleMicros   只许 WindowSettle（定义）/ FloatSettle（消费）——Batch 6
//                                 修掉的 budgetMs 单位 bug（300_000ms 预算）源头即此值的
//                                 裸传；新消费者必须经 FloatSettle。
// R3  setWindowFloat(             只许定义处 / 通道 protocol 声明 / FloatSettle 接线 /
//                                 restore 4a 通道闭包 / TerminalGrid 投递（文档化的刻意旁路）。
// R4  "--toggle", "float"         原始 yabai float 切换只在 SpaceController+Move（定义处）。
// R5  AXUIElementSetAttributeValue × kAXSizeAttribute/kAXPositionAttribute
//                                 frame 写只许 WindowManager+AXWrite（写原语）/
//                                 MoveWindow+PostMove（post-check 重写兜底）。
// R7  clearWindowQueryCache()|clearQueryCache()
//                                 查询缓存失效只许定义处 / restore 通道声明与守卫内部 /
//                                 FloatSettle 恒清接线（Batch 6 三档归一）。
// R8  FloatSettle.floatAndSettle( 唯一序列原语的合法接线点只许 WindowManager+Layout 包装 /
//                                 ToggleEngine+Restore 4a——新调用点=新手抄，必须走审查。
// R9  MoveToMainPipeline.run(     move_to_main 阶段管线唯一入口（Batch 7）。
// R10 FrameWriteExecutor(         两段写入执行器唯一实例化点（Batch 3）。

import Foundation

// MARK: - Test harness

var passed = 0
var failed = 0
func check(_ name: String, _ condition: Bool) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("FAIL: \(name)")
    }
}

// 仓库根 = 本文件位于 <root>/Tests/Standalone/
let testFilePath = URL(fileURLWithPath: #filePath)
let repoRoot = testFilePath.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let sourcesRoot = repoRoot.appendingPathComponent("Sources")

// MARK: - 规则表（模式 → 合法消费文件）

struct ConformanceRule {
    let id: String
    let description: String
    /// 匹配任一主模式即候选命中（行级子串）。
    let patterns: [String]
    /// 非空时：行内还须命中至少一个上下文模式才算命中（如 AX 写 × frame 属性，
    /// 排除 title/focus 等其它属性的 AX 写）。
    let contextAnyPatterns: [String]
    /// 合法消费文件名（含定义处）。新增合法出口 = 显式修改这里。
    let allowedFiles: Set<String>
}

let rules: [ConformanceRule] = [
    ConformanceRule(
        id: "R1",
        description: "waitForRelayout( 只许 FrameConvergence/FloatSettle",
        patterns: ["waitForRelayout("],
        contextAnyPatterns: [],
        allowedFiles: ["FrameConvergence.swift", "FloatSettle.swift"]
    ),
    ConformanceRule(
        id: "R2",
        description: "floatRelayoutSettleMicros 只许 WindowSettle/FloatSettle",
        patterns: ["floatRelayoutSettleMicros"],
        contextAnyPatterns: [],
        allowedFiles: ["WindowSettle.swift", "FloatSettle.swift"]
    ),
    ConformanceRule(
        id: "R3",
        description: "setWindowFloat( 只许定义/protocol 声明/三处接线/TerminalGrid 刻意旁路",
        patterns: ["setWindowFloat("],
        contextAnyPatterns: [],
        allowedFiles: [
            "SpaceController+Move.swift",
            "RestoreSwitchOrchestration.swift",
            "WindowManager+Layout.swift",
            "ToggleEngine+Restore.swift",
            "TerminalGridController+SpaceDelivery.swift",
        ]
    ),
    ConformanceRule(
        id: "R4",
        description: "原始 yabai float 切换只在 SpaceController+Move",
        patterns: ["\"--toggle\", \"float\""],
        contextAnyPatterns: [],
        allowedFiles: ["SpaceController+Move.swift"]
    ),
    ConformanceRule(
        id: "R5",
        description: "AX frame 写（size/position 属性）只许写原语与 post-check 重写",
        patterns: ["AXUIElementSetAttributeValue"],
        contextAnyPatterns: ["kAXSizeAttribute", "kAXPositionAttribute"],
        allowedFiles: [
            "WindowManager+AXWrite.swift",
            "WindowManager+MoveWindow+PostMove.swift",
            "WindowManager+WindowQuery.swift",
        ]
    ),
    ConformanceRule(
        id: "R7",
        description: "查询缓存失效只许定义处/restore 通道与守卫/FloatSettle 接线",
        patterns: ["clearWindowQueryCache()", "clearQueryCache()"],
        contextAnyPatterns: [],
        allowedFiles: [
            "SpaceController.swift",
            "RestoreSwitchOrchestration.swift",
            "ToggleEngine+Restore.swift",
            "WindowManager+Layout.swift",
        ]
    ),
    ConformanceRule(
        id: "R8",
        description: "FloatSettle.floatAndSettle( 只许两处生产接线（新增=新手抄）",
        patterns: ["FloatSettle.floatAndSettle("],
        contextAnyPatterns: [],
        allowedFiles: ["FloatSettle.swift", "WindowManager+Layout.swift", "ToggleEngine+Restore.swift"]
    ),
    ConformanceRule(
        id: "R9",
        description: "MoveToMainPipeline.run( 唯一入口（Batch 7 阶段管线）",
        patterns: ["MoveToMainPipeline.run("],
        contextAnyPatterns: [],
        allowedFiles: ["MoveToMainPipeline.swift", "WindowManager+MoveWindow.swift"]
    ),
    ConformanceRule(
        id: "R10",
        description: "FrameWriteExecutor( 唯一实例化点（Batch 3 执行器）",
        patterns: ["FrameWriteExecutor("],
        contextAnyPatterns: [],
        allowedFiles: ["FrameWriteExecutor.swift", "WindowManager+MoveWindow.swift"]
    ),
]

// MARK: - 扫描

func isCommentLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
}

/// 单行命中判定（纯函数，自测锁定）：主模式命中 + 上下文（如要求）命中 + 文件不在白名单。
func isViolation(line: String, basename: String, rule: ConformanceRule) -> Bool {
    let primary = rule.patterns.contains { line.contains($0) }
    let contextOK = rule.contextAnyPatterns.isEmpty || rule.contextAnyPatterns.contains { line.contains($0) }
    return primary && contextOK && !rule.allowedFiles.contains(basename)
}

// 检测器自测：守门者自己必须被证明能抓违例、能放行合法形态。
do {
    let r1 = rules[0]
    check("selftest: R1 命中白名单外文件的手抄调用",
          isViolation(line: "        FrameConvergence.waitForRelayout(\n", basename: "Foo.swift", rule: r1))
    check("selftest: R1 放行白名单内文件",
          !isViolation(line: "FrameConvergence.waitForRelayout(\n", basename: "FloatSettle.swift", rule: r1))

    let r5 = rules.first { $0.id == "R5" }!
    check("selftest: R5 命中白名单外的 AX size 写",
          isViolation(line: "_ = AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, v)\n", basename: "Foo.swift", rule: r5))
    check("selftest: R5 放行 title 写（上下文属性不匹配）",
          !isViolation(line: "AXUIElementSetAttributeValue(window, kAXTitleAttribute as CFString, t)\n", basename: "Foo.swift", rule: r5))
    check("selftest: R5 放行 focus 写（上下文属性不匹配）",
          !isViolation(line: "AXUIElementSetAttributeValue(ax, kAXFocusedAttribute as CFString, true)\n", basename: "Foo.swift", rule: r5))

    let r8 = rules.first { $0.id == "R8" }!
    check("selftest: R8 命中第三处手抄 float-settle",
          isViolation(line: "    _ = FloatSettle.floatAndSettle(windowID: id, ...)\n", basename: "Foo.swift", rule: r8))
}

guard FileManager.default.fileExists(atPath: sourcesRoot.path) else {
    print("FAIL: 找不到 Sources/ 目录（repoRoot=\(repoRoot.path)）")
    exit(1)
}

let enumerator = FileManager.default.enumerator(atPath: sourcesRoot.path)
var swiftFiles: [String] = []
while let relative = enumerator?.nextObject() as? String {
    if relative.hasSuffix(".swift") {
        swiftFiles.append(relative)
    }
}
swiftFiles.sort()
check("扫描到 Sources 下的 swift 文件（>40）", swiftFiles.count > 40)

var violations: [String] = []
var ruleHits: [String: Int] = [:]

for relative in swiftFiles {
    let basename = (relative as NSString).lastPathComponent
    let content = try? String(contentsOfFile: sourcesRoot.appendingPathComponent(relative).path, encoding: .utf8)
    guard let lines = content?.components(separatedBy: .newlines) else {
        violations.append("READ-FAIL \(relative)")
        continue
    }
    for (index, line) in lines.enumerated() where !isCommentLine(line) {
        for rule in rules {
            if isViolation(line: line, basename: basename, rule: rule) {
                violations.append("\(rule.id) \(relative):\(index + 1)  [\(line.trimmingCharacters(in: .whitespaces).prefix(110))]")
                ruleHits[rule.id, default: 0] += 1
            }
        }
    }
}

// MARK: - 断言与报告

check("零违例（\(violations.count) 处）", violations.isEmpty)
for v in violations {
    print("  违例: \(v)")
}

print("\n规则覆盖（命中行数为 0 = 当前无绕过，白名单即消费方清单）：")
for rule in rules {
    let hits = ruleHits[rule.id] ?? 0
    let state = hits == 0 ? "OK" : "VIOLATED"
    print("  [\(state)] \(rule.id): \(rule.description)（违例 \(hits) 处）")
}

print("\nArchitectureConformanceTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
