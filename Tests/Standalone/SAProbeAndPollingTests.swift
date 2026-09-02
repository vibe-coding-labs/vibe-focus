// Tests/Standalone/SAProbeAndPollingTests.swift
// Verification: SA 探针裁决 + 等到位有界轮询（分支穷尽，playbook 2.13 口径）
// Mirrors: Sources/Space/SpaceController+Recovery.swift saProbeVerdict
//          Sources/Space/YabaiErrorClassifier.swift classify
//          Sources/Support/ConditionPolling.swift waitUntil
// Run: swift Tests/Standalone/SAProbeAndPollingTests.swift

import Foundation

// MARK: - Mirrors (与源码同步维护；Swift Testing 版在 Tests/XCTest/SAProbeAndPollingTests.swift)

enum MirrorYabaiErrorKind: Equatable {
    case scriptingAdditionMissing
    case missionControlBlocking
    case noFocusedWindow
    case windowNotFound
    case unrecognized
    case none
}

func classify(stderr: String) -> MirrorYabaiErrorKind {
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

func saProbeVerdict(exitCode: Int32, stderr: String) -> Bool {
    if exitCode == 0 { return true }
    let kind = classify(stderr: stderr)
    return kind != .scriptingAdditionMissing && kind != .missionControlBlocking
}

enum MirrorConditionPollOutcome: Equatable {
    case satisfied(checks: Int)
    case exhausted

    /// 是否在预算内到位（与 Sources/Support/ConditionPolling.swift 同步维护）。
    var satisfied: Bool {
        if case .satisfied = self { return true }
        return false
    }
}

func waitUntil(
    intervalMs: UInt32,
    budgetMs: UInt32,
    sleep: (UInt32) -> Void,
    condition: () -> Bool
) -> MirrorConditionPollOutcome {
    var checks = 0
    var waitedMs: UInt32 = 0
    checks += 1
    if condition() {
        return .satisfied(checks: checks)
    }
    while waitedMs < budgetMs {
        let remaining = budgetMs - waitedMs
        let nap = min(intervalMs, remaining)
        sleep(nap)
        waitedMs += nap
        checks += 1
        if condition() {
            return .satisfied(checks: checks)
        }
    }
    return .exhausted
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: - saProbeVerdict

check("exit 0 = 命令成功，SA 必在", saProbeVerdict(exitCode: 0, stderr: "") && saProbeVerdict(exitCode: 0, stderr: "anything"))

check("stderr 报 scripting-addition = 未加载",
      !saProbeVerdict(exitCode: 1, stderr: "yabai: error with the scripting-addition"))

check("Mission Control 阻塞 = 期间切换不可用，如实上报不可用",
      !saProbeVerdict(exitCode: 1, stderr: "yabai: cannot focus space: mission-control is active!"))

check("已聚焦 space 的逻辑错误 = SA 可用（探针无副作用路径）",
      saProbeVerdict(exitCode: 1, stderr: "cannot focus an already focused space."))

check("空 stderr 与查询类预期失败 = SA 可用",
      saProbeVerdict(exitCode: 1, stderr: "")
      && saProbeVerdict(exitCode: 1, stderr: "could not retrieve window details")
      && saProbeVerdict(exitCode: 1, stderr: "could not locate window"))

check("未识别 stderr 按可用放行（分类器兜底，不误杀 SA）",
      saProbeVerdict(exitCode: 1, stderr: "something unexpected happened"))

check("大小写不敏感（防输出漂移）",
      !saProbeVerdict(exitCode: 1, stderr: "ERROR WITH THE SCRIPTING-ADDITION"))

// MARK: - ConditionPolling.waitUntil

var sleepCount = 0
check("首查即满足 → 零等待 satisfied(checks:1)",
      waitUntil(intervalMs: 50, budgetMs: 800, sleep: { _ in sleepCount += 1 }, condition: { true }) == .satisfied(checks: 1)
      && sleepCount == 0)

var polls = 0
var naps = 0
check("第 3 次检查满足 → sleep 2 次（check/sleep 严格交替）",
      waitUntil(intervalMs: 50, budgetMs: 800,
                sleep: { _ in naps += 1 },
                condition: { polls += 1; return polls >= 3 }) == .satisfied(checks: 3)
      && naps == 2)

var timeoutNaps = 0
check("预算耗尽仍不满足 → exhausted（sleep 次数 = budget/interval）",
      waitUntil(intervalMs: 50, budgetMs: 800,
                sleep: { _ in timeoutNaps += 1 },
                condition: { false }) == .exhausted
      && timeoutNaps == 16)

var zeroBudgetSleeps = 0
check("budget=0 且条件不满足 → 只首查不睡",
      waitUntil(intervalMs: 50, budgetMs: 0,
                sleep: { _ in zeroBudgetSleeps += 1 },
                condition: { false }) == .exhausted
      && zeroBudgetSleeps == 0)

var clampedNaps: [UInt32] = []
check("interval > 剩余预算时末轮钳制",
      waitUntil(intervalMs: 200, budgetMs: 100,
                sleep: { clampedNaps.append($0) },
                condition: { false }) == .exhausted
      && clampedNaps == [100])

let miss = waitUntil(intervalMs: 50, budgetMs: 800, sleep: { _ in }, condition: { false })
let hit = waitUntil(intervalMs: 50, budgetMs: 800, sleep: { _ in }, condition: { true })
check("satisfied 便捷判定两分支", !miss.satisfied && hit.satisfied)

// MARK: - Summary

print("\nSAProbeAndPollingTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
