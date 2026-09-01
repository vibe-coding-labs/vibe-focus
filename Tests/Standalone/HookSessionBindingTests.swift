// Tests/Standalone/HookSessionBindingTests.swift
// Verification: 会话→窗口绑定解析编排（Stop 与 UPS 共用路径）
// Mirrors: Sources/Hook/HookEventHandler+WindowResolution.swift
//          （decideSessionBindingStep / SessionBindingOutcome 分支表）
//          Sources/Hook/HookEventHandler+WindowMove.swift（outcome → WindowMoveDecision 映射）
// Run: swift Tests/Standalone/HookSessionBindingTests.swift
//
// 背景（playbook 2.16a 第十一步刀）："绑定查找 + machineLabel 自愈 + 注册 + 活性校验"
// 曾在 UPS 与 Stop 两路各写一份（校验时序与日志漂移：UPS 自愈后不校验）。
// 收敛后本测试锁定：分支决策顺序（有绑定先验证、自愈只救无绑定）、
// 自愈产物同样过活性校验、两种调用方的 outcome → 响应映射。

import Foundation

// MARK: - Extracted pure logic

/// Mirrors SessionBindingStep
enum MirrorSessionBindingStep: Equatable {
    case verifyExisting
    case attemptSelfHeal
    case giveUp
}

/// Mirrors HookEventHandler.decideSessionBindingStep
func mirrorDecideSessionBindingStep(hasBinding: Bool, machineLabel: String?) -> MirrorSessionBindingStep {
    if hasBinding { return .verifyExisting }
    if let label = machineLabel, !label.isEmpty { return .attemptSelfHeal }
    return .giveUp
}

/// Mirrors SessionBindingOutcome（携带 windowID 便于断言）
enum MirrorSessionBindingOutcome: Equatable {
    case bound(UInt32)
    case verificationFailed(UInt32)
    case healed(UInt32)
    case healLost
    case none
}

/// Mirrors resolveSessionBinding 编排（IO 以参数注入）——分支结构必须与生产一致
func mirrorResolveSessionBinding(
    hasBinding: Bool,
    bindingVerified: Bool,
    machineLabel: String?,
    labelMapped: Bool = true,
    healWindowFound: Bool = true,
    refetchFound: Bool = true,
    healedVerified: Bool = true,
    windowID: UInt32 = 42
) -> MirrorSessionBindingOutcome {
    switch mirrorDecideSessionBindingStep(hasBinding: hasBinding, machineLabel: machineLabel) {
    case .verifyExisting:
        return bindingVerified ? .bound(windowID) : .verificationFailed(windowID)
    case .attemptSelfHeal:
        guard labelMapped, healWindowFound else { return .none }
        guard refetchFound else { return .healLost }
        guard healedVerified else { return .verificationFailed(windowID) }
        return .healed(windowID)
    case .giveUp:
        return .none
    }
}

/// Mirrors handleWindowMoveTrigger 的 outcome → WindowMoveDecision 映射
func mirrorMoveMapping(_ outcome: MirrorSessionBindingOutcome) -> String {
    switch outcome {
    case .bound, .healed:
        return "proceed_to_tail"   // 进入 decideWindowMove 尾部决策（第五刀 39 项测试已锁）
    case .verificationFailed:
        return "binding_verification_failed"
    case .healLost:
        return "self_heal_binding_lost"   // 特例响应文案 "Self-heal binding lost after registration"
    case .none:
        return "no_binding_skip"
    }
}

/// Mirrors resolveWindowIdentity 的 outcome → WindowIdentity? 映射
func mirrorUPSMapping(_ outcome: MirrorSessionBindingOutcome) -> String {
    switch outcome {
    case .bound, .healed:
        return "identity"
    case .verificationFailed, .healLost, .none:
        return "nil"
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: 1. 分支决策 — 有绑定先验证、自愈只救无绑定

print("1. decideSessionBindingStep — 分支顺序")

check("有绑定 → verifyExisting（即使有 label 也不自愈）",
      mirrorDecideSessionBindingStep(hasBinding: true, machineLabel: "remote-1") == .verifyExisting)
check("无绑定 + label 非空 → attemptSelfHeal",
      mirrorDecideSessionBindingStep(hasBinding: false, machineLabel: "remote-1") == .attemptSelfHeal)
check("无绑定 + label 为空串 → giveUp",
      mirrorDecideSessionBindingStep(hasBinding: false, machineLabel: "") == .giveUp)
check("无绑定 + label 为 nil → giveUp",
      mirrorDecideSessionBindingStep(hasBinding: false, machineLabel: nil) == .giveUp)

// MARK: 2. outcome 决策表 — 既有绑定路径

print("\n2. 既有绑定路径")

check("绑定存在 + 校验通过 → bound",
      mirrorResolveSessionBinding(hasBinding: true, bindingVerified: true, machineLabel: nil) == .bound(42))
check("绑定存在 + 校验失败（PID 消失/易主）→ verificationFailed",
      mirrorResolveSessionBinding(hasBinding: true, bindingVerified: false, machineLabel: "remote-1") == .verificationFailed(42))

// MARK: 3. outcome 决策表 — 自愈路径（含全部失败形态）

print("\n3. 自愈路径")

check("label 映射存在 + 窗口存活 + 注册 + 重取 + 校验 → healed",
      mirrorResolveSessionBinding(hasBinding: false, bindingVerified: false, machineLabel: "remote-1") == .healed(42))
check("label 未映射（远程绑定表无此机）→ none",
      mirrorResolveSessionBinding(hasBinding: false, bindingVerified: false, machineLabel: "remote-1",
                                  labelMapped: false) == .none)
check("映射窗口已消失 → none",
      mirrorResolveSessionBinding(hasBinding: false, bindingVerified: false, machineLabel: "remote-1",
                                  healWindowFound: false) == .none)
check("bind 后立即重取失败（竞态）→ healLost",
      mirrorResolveSessionBinding(hasBinding: false, bindingVerified: false, machineLabel: "remote-1",
                                  refetchFound: false) == .healLost)
check("自愈产物未过活性校验 → verificationFailed（统一不变量：凡交付必先校验）",
      mirrorResolveSessionBinding(hasBinding: false, bindingVerified: false, machineLabel: "remote-1",
                                  healedVerified: false) == .verificationFailed(42))

// MARK: 4. 调用方映射 — Stop 与 UPS 对同一 outcome 的不同响应

print("\n4. 调用方映射表")

let allOutcomes: [MirrorSessionBindingOutcome] = [
    .bound(42), .verificationFailed(42), .healed(42), .healLost, .none
]

for outcome in allOutcomes {
    let move = mirrorMoveMapping(outcome)
    let ups = mirrorUPSMapping(outcome)
    check("\(outcome) → Stop[\(move)] / UPS[\(ups)]",
          move != "" && ups != "")
}

check("bound 与 healed 在两侧都等价放行（Stop 进尾部决策 / UPS 得 identity）",
      mirrorMoveMapping(.bound(42)) == mirrorMoveMapping(.healed(42)) &&
      mirrorUPSMapping(.bound(42)) == mirrorUPSMapping(.healed(42)))
check("healLost 走专有响应文案（区别于普通 no_binding_skip）",
      mirrorMoveMapping(.healLost) == "self_heal_binding_lost")
check("verificationFailed 在两侧都不放行",
      mirrorUPSMapping(.verificationFailed(42)) == "nil" &&
      mirrorMoveMapping(.verificationFailed(42)) == "binding_verification_failed")

// MARK: 5. 端到端场景 — 真实事件序列

print("\n5. 端到端场景")

// 场景 A：远程 session 首个 Stop 事件（无绑定，label 可自愈）
check("远程首 Stop：自愈成功 → healed → 拉窗",
      mirrorMoveMapping(mirrorResolveSessionBinding(
          hasBinding: false, bindingVerified: false, machineLabel: "remote-1")) == "proceed_to_tail")

// 场景 B：SessionStart 已绑定 → Stop 到来时窗口已被用户关闭
check("窗口已关：绑定失效 → binding_verification_failed（不误拉别的窗口）",
      mirrorMoveMapping(mirrorResolveSessionBinding(
          hasBinding: true, bindingVerified: false, machineLabel: "remote-1")) == "binding_verification_failed")

// 场景 C：本地 session 无远程上下文，UPS 到来
check("本地 UPS：无绑定无 label → none → UPS 不动作",
      mirrorUPSMapping(mirrorResolveSessionBinding(
          hasBinding: false, bindingVerified: false, machineLabel: nil)) == "nil")

// 场景 D：自愈产物是易主窗口（heal 后校验拦截）
check("自愈产物易主：healed 路径同样被校验拦截（统一不变量）",
      mirrorResolveSessionBinding(hasBinding: false, bindingVerified: false, machineLabel: "remote-1",
                                  healedVerified: false) == .verificationFailed(42))

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
