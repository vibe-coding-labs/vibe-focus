import Testing
import Foundation
@testable import VibeFocusKit

/// restore 专项新增纯决策的分支穷尽锁定（playbook 2.13 验收口径）：
/// 1. SpaceController.saProbeVerdict — SA 探针裁决（v7 陈旧判据重写后的事实源）；
/// 2. ConditionPolling.waitUntil — 等到位有界轮询骨架（P1-2）。
@Suite("SA Probe Verdict & Condition Polling")
struct SAProbeAndPollingTests {

    // MARK: - saProbeVerdict

    @Test("saProbeVerdict: exit 0 = 命令成功，SA 必在")
    func exitZeroMeansLoaded() {
        #expect(SpaceController.saProbeVerdict(exitCode: 0, stderr: ""))
        #expect(SpaceController.saProbeVerdict(exitCode: 0, stderr: "anything"))
    }

    @Test("saProbeVerdict: stderr 报 scripting-addition = 未加载")
    func scriptingAdditionErrorMeansMissing() {
        #expect(!SpaceController.saProbeVerdict(exitCode: 1, stderr: "yabai: error with the scripting-addition"))
    }

    @Test("saProbeVerdict: Mission Control 阻塞 = 期间 space 切换不可用，如实上报不可用")
    func missionControlMeansUnavailable() {
        // 串用分类器契约特征串（"mission-control" 连字符，第八刀收敛）；真实输出若为
        // "mission control"（无连字符）分类为 unrecognized → 放行为可用，语义仍可接受
        // （MC 是瞬时态，SA 本身并未缺失）。
        #expect(!SpaceController.saProbeVerdict(exitCode: 1, stderr: "yabai: cannot focus space: mission-control is active!"))
    }

    @Test("saProbeVerdict: 已聚焦 space 的逻辑错误 = SA 可用（探针的无副作用路径）")
    func alreadyFocusedMeansLoaded() {
        #expect(SpaceController.saProbeVerdict(exitCode: 1, stderr: "cannot focus an already focused space."))
    }

    @Test("saProbeVerdict: 空 stderr 与查询类预期失败 = SA 可用")
    func otherKnownErrorsMeansLoaded() {
        #expect(SpaceController.saProbeVerdict(exitCode: 1, stderr: ""))
        #expect(SpaceController.saProbeVerdict(exitCode: 1, stderr: "could not retrieve window details"))
        #expect(SpaceController.saProbeVerdict(exitCode: 1, stderr: "could not locate window"))
    }

    @Test("saProbeVerdict: 未识别 stderr 按可用放行（分类器兜底，不误杀 SA）")
    func unrecognizedMeansLoaded() {
        #expect(SpaceController.saProbeVerdict(exitCode: 1, stderr: "something unexpected happened"))
    }

    @Test("saProbeVerdict: 大小写不敏感（真实 yabai 输出恒小写，防漂移）")
    func caseInsensitive() {
        #expect(!SpaceController.saProbeVerdict(exitCode: 1, stderr: "ERROR WITH THE SCRIPTING-ADDITION"))
    }

    // MARK: - ConditionPolling.waitUntil

    @Test("轮询: 首查即满足 → 零等待（satisfied(checks: 1)，未 sleep）")
    func immediateSatisfySkipsSleep() {
        var sleepCount = 0
        let outcome = ConditionPolling.waitUntil(
            intervalMs: 50, budgetMs: 800,
            sleep: { _ in sleepCount += 1 },
            condition: { true }
        )
        #expect(outcome == .satisfied(checks: 1))
        #expect(sleepCount == 0)
    }

    @Test("轮询: 第 3 次检查满足 → sleep 2 次（check → sleep → check 严格交替）")
    func satisfyAfterNaps() {
        var sleepCount = 0
        var polls = 0
        let outcome = ConditionPolling.waitUntil(
            intervalMs: 50, budgetMs: 800,
            sleep: { _ in sleepCount += 1 },
            condition: { polls += 1; return polls >= 3 }
        )
        #expect(outcome == .satisfied(checks: 3))
        #expect(sleepCount == 2)
    }

    @Test("轮询: 预算耗尽仍不满足 → exhausted（sleep 次数 = budget/interval）")
    func exhaustsOnTimeout() {
        var sleepCount = 0
        let outcome = ConditionPolling.waitUntil(
            intervalMs: 50, budgetMs: 800,
            sleep: { _ in sleepCount += 1 },
            condition: { false }
        )
        #expect(outcome == .exhausted)
        #expect(sleepCount == 16)
    }

    @Test("轮询: budget=0 且条件不满足 → 只首查不睡")
    func zeroBudgetOnlyProbesOnce() {
        var sleepCount = 0
        let outcome = ConditionPolling.waitUntil(
            intervalMs: 50, budgetMs: 0,
            sleep: { _ in sleepCount += 1 },
            condition: { false }
        )
        #expect(outcome == .exhausted)
        #expect(sleepCount == 0)
    }

    @Test("轮询: interval > 剩余预算时末轮钳制，不长睡超预算")
    func lastNapClampedToRemainingBudget() {
        var slept: [UInt32] = []
        let outcome = ConditionPolling.waitUntil(
            intervalMs: 200, budgetMs: 100,
            sleep: { slept.append($0) },
            condition: { false }
        )
        #expect(outcome == .exhausted)
        #expect(slept == [100])
    }

    @Test("轮询结局: satisfied 便捷判定两分支")
    func satisfiedConvenienceVar() {
        let miss = ConditionPolling.waitUntil(intervalMs: 50, budgetMs: 800, sleep: { _ in }, condition: { false })
        let hit = ConditionPolling.waitUntil(intervalMs: 50, budgetMs: 800, sleep: { _ in }, condition: { true })
        #expect(!miss.satisfied)
        #expect(hit.satisfied)
    }

    @Test("轮询: 默认 usleep 通道可用（实跑 1ms）")
    func defaultSleepChannelWorks() {
        var polls = 0
        let outcome = ConditionPolling.waitUntil(intervalMs: 1, budgetMs: 1, condition: { polls += 1; return polls >= 2 })
        #expect(outcome == .satisfied(checks: 2))
    }
}
