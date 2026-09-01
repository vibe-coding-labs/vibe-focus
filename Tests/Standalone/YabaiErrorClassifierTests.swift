// Tests/Standalone/YabaiErrorClassifierTests.swift
// Verification: yabai stderr 错误分类（4 处散落字符串协议的收敛点）
// Mirrors: Sources/Space/YabaiErrorClassifier.swift（YabaiErrorKind / classify）
// Run: swift Tests/Standalone/YabaiErrorClassifierTests.swift
//
// 背景（playbook 2.16 第八刀）：4 个生产点各自裸写 stderr.contains("...")，
// 匹配语义漂移（有的 lowercased 有的不转）。收敛后本测试锁定：
// 特征子串、大小写不敏感、优先级顺序、空/未知输出归类。
// fixture 采用真实 yabai 报错样式（含前缀命令名与换行）。

import Foundation

// MARK: - Extracted pure logic

/// Mirrors YabaiErrorKind
enum MirrorYabaiErrorKind: Equatable {
    case scriptingAdditionMissing
    case missionControlBlocking
    case noFocusedWindow
    case windowNotFound
    case unrecognized
    case none
}

/// Mirrors YabaiErrorClassifier（patterns 表 + classify）
func mirrorClassify(_ stderr: String) -> MirrorYabaiErrorKind {
    let patterns: [(MirrorYabaiErrorKind, String)] = [
        (.scriptingAdditionMissing, "scripting-addition"),
        (.missionControlBlocking, "mission-control"),
        (.noFocusedWindow, "could not retrieve window details"),
        (.windowNotFound, "could not locate window"),
    ]
    let lowered = stderr.lowercased()
    guard !lowered.isEmpty else { return .none }
    for (kind, pattern) in patterns where lowered.contains(pattern) {
        return kind
    }
    return .unrecognized
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func checkKind(_ name: String, _ stderr: String, _ expected: MirrorYabaiErrorKind) {
    check(name, mirrorClassify(stderr) == expected)
}

// MARK: 1. 四类已知错误 — 真实 yabai 报错样式 fixture

print("1. 已知错误归类 — 真实报错样式")

checkKind("SA 未加载（query --window 失败回退路径）",
          "yabai: cannot touch window: scripting-addition is not loaded\n",
          .scriptingAdditionMissing)
checkKind("MC 阻塞（space --focus）",
          "yabai -m space --focus 3: could not focus space: mission-control is active",
          .missionControlBlocking)
checkKind("无焦点窗口（query --windows --window，用户点桌面）",
          "could not retrieve window details.",
          .noFocusedWindow)
checkKind("窗口已关闭（query --windows --window <id>）",
          "could not locate window.",
          .windowNotFound)

// MARK: 2. 大小写不敏感 — 统一后对漂移稳健

print("\n2. 大小写不敏感")

checkKind("大写 SA 报错也命中（历史部分站点不转小写的缺口）",
          "SCRIPTING-ADDITION NOT LOADED", .scriptingAdditionMissing)
checkKind("大写 MC 报错也命中",
          "Mission-Control is active", .missionControlBlocking)
checkKind("混合大小写无焦点窗口",
          "Could Not Retrieve Window Details", .noFocusedWindow)

// MARK: 3. 空/未知输出

print("\n3. 空与未知")

checkKind("空串 → none", "", .none)
checkKind("纯空白 → unrecognized（空白非空；历史 contains 对空白为 false 走异常分支）",
          "   \n", .unrecognized)
checkKind("未识别报错 → unrecognized", "yabai: something exploded", .unrecognized)
checkKind("部分相似但非特征串 → unrecognized",
          "could not retrieve space list", .unrecognized)

// MARK: 4. 优先级 — 同一 stderr 命中多类时取表序最前

print("\n4. 优先级（SA > MC > 无焦点 > 窗口不存在）")

checkKind("SA + MC 同时出现 → SA（系统性故障优先）",
          "mission-control active; scripting-addition missing", .scriptingAdditionMissing)
checkKind("无焦点 + 窗口不存在同时出现 → 无焦点",
          "could not locate window; could not retrieve window details", .noFocusedWindow)
checkKind("MC + 窗口不存在同时出现 → MC",
          "could not locate window after mission-control dismiss", .missionControlBlocking)

// MARK: 5. 子串位置无关 — 前缀/中间/尾部

print("\n5. 子串位置无关")

checkKind("特征串在消息中部",
          "yabai: error: could not retrieve window details: no such window", .noFocusedWindow)
checkKind("多行 stderr 命中第二行",
          "warning: deprecated flag\nscripting-addition not loaded", .scriptingAdditionMissing)

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
