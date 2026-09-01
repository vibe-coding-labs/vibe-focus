// Tests/Standalone/HookWindowMoveRoutingTests.swift
// Verification: handleWindowMoveTrigger 决策树顺序契约（decideWindowMove 守护顺序）
//               + 决策→HTTP 响应映射表（httpResponse(for:)）
// Mirrors: Sources/Hook/HookEventHandler+WindowMove+Decision.swift (WindowMoveDecision /
//          decideWindowMove / httpResponse)
//          Sources/Hook/HookEventHandler+WindowMove.swift (守护顺序 ①—⑤)
// Run: swift Tests/Standalone/HookWindowMoveRoutingTests.swift
//
// 背景（playbook 2.16 第五刀）：生产曾在 handleWindowMoveTrigger 内联重写决策顺序，
// remoteOnly 判定后置在 binding self-heal 之后——被拒事件已产生 bind 持久化副作用。
// 本测试锁定：remoteOnly 必须先于一切绑定判定；尾部四决策（onMain/冷却/过期/非终端）
// 由同一棵树裁决；每个决策的响应码唯一且稳定。

import Foundation

// MARK: - Extracted pure logic

/// Mirrors HookEventHandler.WindowMoveDecision（顺序即生产守护顺序）
enum MirrorWindowMoveDecision: Equatable {
    case autoFocusDisabled
    case localBindingSkip
    case noBindingSkip
    case bindingVerificationFailed
    case alreadyOnMainScreen
    case restoreCooldownActive
    case staleBindingPIDMismatch
    case nonTerminalWindow
    case proceedToMove(source: String)
}

/// Mirrors HookEventHandler.decideWindowMove —— 生产与测试必须守护同一棵树
func mirrorDecideWindowMove(
    autoFocusEnabled: Bool,
    hasBinding: Bool,
    bindingVerified: Bool,
    isWindowOnMainScreen: Bool,
    isInCooldown: Bool,
    bindingAge: TimeInterval,
    pidMatches: Bool?,
    isTerminalOrIDE: Bool,
    remoteOnly: Bool = false
) -> MirrorWindowMoveDecision {
    guard autoFocusEnabled else { return .autoFocusDisabled }
    if remoteOnly { return .localBindingSkip }
    if !hasBinding { return .noBindingSkip }
    guard bindingVerified else { return .bindingVerificationFailed }
    if isWindowOnMainScreen { return .alreadyOnMainScreen }
    if isInCooldown { return .restoreCooldownActive }
    if bindingAge > 1800 && pidMatches == false { return .staleBindingPIDMismatch }
    guard isTerminalOrIDE else { return .nonTerminalWindow }
    return .proceedToMove(source: "binding")
}

/// Mirrors HookEventHandler.httpResponse(for:triggerName:sessionID:)
func mirrorHttpResponse(
    for decision: MirrorWindowMoveDecision,
    triggerName: String,
    sessionID: String
) -> (statusCode: Int, code: String, ok: Bool, handled: Bool)? {
    switch decision {
    case .autoFocusDisabled:
        return (200, "auto_focus_disabled", true, false)
    case .localBindingSkip:
        return (200, "trigger_disabled_skip", true, false)
    case .noBindingSkip:
        return (200, "no_binding_skip", true, false)
    case .bindingVerificationFailed:
        return (200, "binding_verification_failed", true, false)
    case .alreadyOnMainScreen:
        return (200, "already_on_main_screen", true, false)
    case .restoreCooldownActive:
        return (200, "restore_cooldown_active", true, false)
    case .staleBindingPIDMismatch:
        return (200, "stale_binding_pid_mismatch", true, false)
    case .nonTerminalWindow:
        return (200, "non_terminal_window", true, false)
    case .proceedToMove:
        return nil
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func checkDecision(_ name: String, _ result: MirrorWindowMoveDecision, _ expected: MirrorWindowMoveDecision) {
    check(name, result == expected)
}

/// 干净输入：除指定项外全部"放行"
func decide(
    autoFocusEnabled: Bool = true,
    hasBinding: Bool = true,
    bindingVerified: Bool = true,
    isWindowOnMainScreen: Bool = false,
    isInCooldown: Bool = false,
    bindingAge: TimeInterval = 100,
    pidMatches: Bool? = true,
    isTerminalOrIDE: Bool = true,
    remoteOnly: Bool = false
) -> MirrorWindowMoveDecision {
    mirrorDecideWindowMove(
        autoFocusEnabled: autoFocusEnabled,
        hasBinding: hasBinding,
        bindingVerified: bindingVerified,
        isWindowOnMainScreen: isWindowOnMainScreen,
        isInCooldown: isInCooldown,
        bindingAge: bindingAge,
        pidMatches: pidMatches,
        isTerminalOrIDE: isTerminalOrIDE,
        remoteOnly: remoteOnly
    )
}

// MARK: 1. 决策树 — 每个 case 至少一条路径

print("1. 决策树 — 9 case 全覆盖")

checkDecision("autoFocus=false → autoFocusDisabled", decide(autoFocusEnabled: false), .autoFocusDisabled)
checkDecision("remoteOnly=true → localBindingSkip", decide(remoteOnly: true), .localBindingSkip)
checkDecision("无绑定 → noBindingSkip", decide(hasBinding: false), .noBindingSkip)
checkDecision("绑定未通过活性校验 → bindingVerificationFailed", decide(bindingVerified: false), .bindingVerificationFailed)
checkDecision("已在主屏 → alreadyOnMainScreen", decide(isWindowOnMainScreen: true), .alreadyOnMainScreen)
checkDecision("冷却中 → restoreCooldownActive", decide(isInCooldown: true), .restoreCooldownActive)
checkDecision("非终端/IDE → nonTerminalWindow", decide(isTerminalOrIDE: false), .nonTerminalWindow)
checkDecision("全部放行 → proceedToMove(source=binding)", decide(), .proceedToMove(source: "binding"))

// MARK: 2. 顺序契约 — 第五刀修复的核心（remoteOnly 前移的纯函数侧依据）

print("\n2. 顺序契约 — remoteOnly 先于一切绑定判定")

// 生产守护顺序 ①autoFocus → ②remoteOnly → ③binding → ④verify → ⑤尾部
// remoteOnly=true 时即使无绑定/绑定失效，也必须落在 localBindingSkip（生产侧：
// 不做 binding 查找、不做 self-heal bind 持久化，直接拒绝）
checkDecision("remoteOnly + 无绑定 → localBindingSkip（非 noBindingSkip）",
              decide(hasBinding: false, remoteOnly: true), .localBindingSkip)
checkDecision("remoteOnly + 绑定失效 → localBindingSkip（非 bindingVerificationFailed）",
              decide(bindingVerified: false, remoteOnly: true), .localBindingSkip)
checkDecision("remoteOnly + 已在主屏 → localBindingSkip（非 alreadyOnMainScreen）",
              decide(isWindowOnMainScreen: true, remoteOnly: true), .localBindingSkip)

// autoFocus 仍高于 remoteOnly
checkDecision("autoFocus=false + remoteOnly → autoFocusDisabled",
              decide(autoFocusEnabled: false, remoteOnly: true), .autoFocusDisabled)

// verify 先于尾部四决策
checkDecision("绑定失效 + 已在主屏 → bindingVerificationFailed（非 alreadyOnMainScreen）",
              decide(bindingVerified: false, isWindowOnMainScreen: true), .bindingVerificationFailed)

// MARK: 3. stale 分支边界（bindingAge > 1800 严格大于 + pidMatches 三态）

print("\n3. stale 边界 — age 阈值与 pidMatches 三态")

checkDecision("age=1800 恰好阈值 + PID 不匹配 → proceed（严格 >）",
              decide(bindingAge: 1800, pidMatches: false), .proceedToMove(source: "binding"))
checkDecision("age=1800.5 + PID 不匹配 → staleBindingPIDMismatch",
              decide(bindingAge: 1800.5, pidMatches: false), .staleBindingPIDMismatch)
checkDecision("age>1800 + PID 匹配 → proceed",
              decide(bindingAge: 3600, pidMatches: true), .proceedToMove(source: "binding"))
checkDecision("age>1800 + 窗口已消失(nil) → proceed（无法证伪即放行）",
              decide(bindingAge: 3600, pidMatches: nil), .proceedToMove(source: "binding"))
checkDecision("age<1800 + PID 不匹配 → proceed（年轻绑定不做 PID 归因）",
              decide(bindingAge: 60, pidMatches: false), .proceedToMove(source: "binding"))
checkDecision("冷却优先于 stale",
              decide(isInCooldown: true, bindingAge: 3600, pidMatches: false), .restoreCooldownActive)
checkDecision("onMain 优先于冷却",
              decide(isWindowOnMainScreen: true, isInCooldown: true), .alreadyOnMainScreen)

// MARK: 4. 响应映射表 — 决策 ↔ 响应码唯一对照

print("\n4. httpResponse 映射表 — 8 个跳过类决策 + proceed=nil")

let allSkips: [(MirrorWindowMoveDecision, String)] = [
    (.autoFocusDisabled, "auto_focus_disabled"),
    (.localBindingSkip, "trigger_disabled_skip"),
    (.noBindingSkip, "no_binding_skip"),
    (.bindingVerificationFailed, "binding_verification_failed"),
    (.alreadyOnMainScreen, "already_on_main_screen"),
    (.restoreCooldownActive, "restore_cooldown_active"),
    (.staleBindingPIDMismatch, "stale_binding_pid_mismatch"),
    (.nonTerminalWindow, "non_terminal_window"),
]
for (decision, expectedCode) in allSkips {
    guard let resp = mirrorHttpResponse(for: decision, triggerName: "Stop", sessionID: "s-1") else {
        check("\(expectedCode) → 有响应", false)
        continue
    }
    check("\(expectedCode) → 200/\(expectedCode)", resp.statusCode == 200 && resp.code == expectedCode)
    check("\(expectedCode) → ok=true, handled=false", resp.ok && !resp.handled)
}

check("proceedToMove → nil（成功/失败响应由执行器产生）",
      mirrorHttpResponse(for: .proceedToMove(source: "binding"), triggerName: "Stop", sessionID: "s-1") == nil)

// MARK: 5. 生产守护顺序完整性 — 输入收集侧约束

print("\n5. 输入收集约束 — stale PID 证据按需收集")

// 生产在 bindingAge > 1800 时才做 CGWindowList 扫描（pidMatches 按需收集），
// 纯函数仅在 age > 1800 时消费 pidMatches——两侧约束必须同时成立，否则要么
// 白扫一遍（性能回退）要么过期绑定漏检。
check("age=1800 时 pidMatches=false 不影响结果（生产此时不扫描）",
      decide(bindingAge: 1800, pidMatches: false) == .proceedToMove(source: "binding"))
check("age>1800 时 pidMatches 才被消费",
      decide(bindingAge: 1801, pidMatches: false) == .staleBindingPIDMismatch)

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
