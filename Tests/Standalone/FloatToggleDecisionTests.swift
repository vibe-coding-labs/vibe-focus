// Tests/Standalone/FloatToggleDecisionTests.swift
// Verification: float 脱管跳过/执行的纯决策（分支穷尽 + 惰性求值不变量）
// Mirrors: Sources/Space/SpaceController+Move.swift FloatToggleOutcome / floatToggleDecision
// Run: swift Tests/Standalone/FloatToggleDecisionTests.swift
//
// 背景（2026-09-02）：setWindowFloat 的 skip 决策此前内联在 I/O 函数体里，restore/toggle
// 两条路径消费其结局决定是否等 300ms 重摆。决策抽成纯函数后，本测试锁定：
// 决策序 disabled → query_nil → already_floating → unmanaged → toggled，
// 以及 disabled 时不得发起 queryWindow fork 的惰性不变量。

import Foundation

// MARK: - Mirrors (与源码同步维护)

enum MirrorFloatToggleOutcome: Equatable {
    case toggled
    case skippedNoOp

    var didToggle: Bool { self == .toggled }
}

struct YabaiWindowInfoMirror {
    let isFloating: Bool
    let isManageableByYabai: Bool
}

func floatToggleDecision(
    isEnabled: Bool,
    info: @autoclosure () -> YabaiWindowInfoMirror?
) -> (outcome: MirrorFloatToggleOutcome, skipReason: String) {
    guard isEnabled else { return (.skippedNoOp, "disabled") }
    guard let info = info() else { return (.skippedNoOp, "query_nil") }
    if info.isFloating {
        return (.skippedNoOp, "already_floating")
    }
    if !info.isManageableByYabai {
        return (.skippedNoOp, "unmanaged")
    }
    return (.toggled, "-")
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func normalWindow() -> YabaiWindowInfoMirror {
    YabaiWindowInfoMirror(isFloating: false, isManageableByYabai: true)
}

// MARK: 1. 决策分支穷尽

print("1. 决策分支穷尽")

check("space 集成关闭 → skip(disabled)",
      floatToggleDecision(isEnabled: false, info: normalWindow()) == (.skippedNoOp, "disabled"))

check("窗口查询失败 → skip(query_nil)",
      floatToggleDecision(isEnabled: true, info: YabaiWindowInfoMirror?.none) == (.skippedNoOp, "query_nil"))

check("窗口已 float → skip(already_floating)（无重摆，调用方无需等 300ms）",
      floatToggleDecision(isEnabled: true, info: YabaiWindowInfoMirror(isFloating: true, isManageableByYabai: true))
          == (.skippedNoOp, "already_floating"))

check("yabai 无法管理（无 AX 引用）→ skip(unmanaged)（toggle 必失败）",
      floatToggleDecision(isEnabled: true, info: YabaiWindowInfoMirror(isFloating: false, isManageableByYabai: false))
          == (.skippedNoOp, "unmanaged"))

check("普通 tiling 窗口 → toggled（有重摆，调用方必须等 300ms）",
      floatToggleDecision(isEnabled: true, info: normalWindow()) == (.toggled, "-"))

// MARK: 2. 分支序不变量（与源码决策序一致，防重排引入行为漂移）

print("\n2. 分支序不变量")

check("已 float 且不可管理的窗口判为 already_floating（floating 检查先于 unmanaged）",
      floatToggleDecision(isEnabled: true, info: YabaiWindowInfoMirror(isFloating: true, isManageableByYabai: false)).skipReason == "already_floating")

check("disabled 优先于一切（即使窗口可正常 toggle）",
      floatToggleDecision(isEnabled: false, info: normalWindow()).outcome == .skippedNoOp)

// MARK: 3. 惰性求值不变量（@autoclosure：disabled 不得发起 queryWindow fork）

print("\n3. 惰性求值不变量")

var queryEvaluated = false
func countedQuery() -> YabaiWindowInfoMirror? {
    queryEvaluated = true
    return normalWindow()
}
_ = floatToggleDecision(isEnabled: false, info: countedQuery())
check("disabled 时 info 闭包未被求值（不发起 queryWindow fork）", !queryEvaluated)

_ = floatToggleDecision(isEnabled: true, info: countedQuery())
check("enabled 时 info 闭包被求值", queryEvaluated)

// MARK: 4. didToggle 映射（restore 4a 段的 settle 依据）

print("\n4. didToggle 映射")

check("toggled.didToggle == true", MirrorFloatToggleOutcome.toggled.didToggle)
check("skippedNoOp.didToggle == false", !MirrorFloatToggleOutcome.skippedNoOp.didToggle)

// MARK: - Summary

print("\nFloatToggleDecisionTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
