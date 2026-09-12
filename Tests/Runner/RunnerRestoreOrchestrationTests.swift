import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerRestoreOrchestrationTests.swift — B56 自 main.swift 按域拆分（逐字搬移，零内容变更）

extension RunnerHarness {
    func runRestoreOrchestrationTests() {
    // MARK: switchSourceSpace（4-pre 源屏预切回双层编排）

    do {
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: nil)
        ch.focusResult = true
        let ok = RestoreSwitchOrchestration.switchSourceSpace(channels: ch, sourceSpace: 3, operationID: "t")
        check("4-pre 编排: SA 可用+直切成功 → true，不再降级聚焦带动",
              ok && ch.calls == ["focus"] && ch.focusReceived == .yabaiIndex(3))
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: nil)
        ch.focusResult = false
        ch.refocusResult = true
        let ok = RestoreSwitchOrchestration.switchSourceSpace(channels: ch, sourceSpace: 3, operationID: "t")
        check("4-pre 编排: SA 直切失败 → 降级聚焦带动成功",
              ok && ch.calls == ["focus", "refocus"] && ch.refocusReceivedSpace == 3)
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: nil)
        ch.focusResult = false
        ch.refocusResult = false
        let ok = RestoreSwitchOrchestration.switchSourceSpace(channels: ch, sourceSpace: 3, operationID: "t")
        check("4-pre 编排: 两层全失败 → false（spaceExact=false 上报）",
              !ok && ch.calls == ["focus", "refocus"])
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        ch.refocusResult = true
        let ok = RestoreSwitchOrchestration.switchSourceSpace(channels: ch, sourceSpace: 3, operationID: "t")
        check("4-pre 编排: SA 不可用 → 不调直切，聚焦带动成功",
              ok && ch.calls == ["refocus"] && ch.refocusReceivedSpace == 3)
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        ch.refocusResult = false
        let ok = RestoreSwitchOrchestration.switchSourceSpace(channels: ch, sourceSpace: 3, operationID: "t")
        check("4-pre 编排: SA 不可用+聚焦带动失败 → false",
              !ok && ch.calls == ["refocus"])
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        _ = RestoreSwitchOrchestration.switchSourceSpace(channels: ch, sourceSpace: 3, operationID: "t")
        check("4-pre 编排: 预切回不 exclude 被恢复窗口（窗口尚未移动，不在源 space 上）",
              ch.refocusReceivedExcluded == nil)
    }

    // MARK: refocusPerspective（视角守卫双层编排）

    do {
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: nil)
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫编排: focused space 查询失败 → noDrift，只做一次查询、不触发任何切回通道",
              outcome == .noDrift && ch.calls == ["current"])
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫编排: 无漂移（current == pre）→ noDrift，只做一次查询、不触发任何切回通道",
              outcome == .noDrift && ch.calls == ["current"])
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 5)
        ch.focusResult = true
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫编排: 漂移+直切成功 → refocused(postSpace=5)，清缓存，不降级",
              outcome == .refocused(postSpace: 5) && ch.calls == ["current", "focus", "clearCache"]
              && ch.focusReceived == .yabaiIndex(1) && ch.cacheCleared)
    }
    do {
        // 轻查询计划：SA=false → spaces 轻查判漂移 + refocusWindowOnSpace（内部 --space 过滤查询+聚焦）
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 5)
        ch.refocusResult = true
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫轻查询: SA=false 漂移+聚焦带动成功 → refocused(5)，fork 序 current/refocus/clearCache",
              outcome == .refocused(postSpace: 5) && ch.calls == ["current", "refocus", "clearCache"]
              && ch.refocusReceivedSpace == 1 && ch.refocusReceivedExcluded == 9)
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 1)
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫轻查询: focused == preMoveSpace → noDrift，仅一次 spaces 轻查",
              outcome == .noDrift && ch.calls == ["current"])
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫轻查询: focused space 查询失败 → noDrift（不盲切语义）",
              outcome == .noDrift && ch.calls == ["current"])
    }
    do {
        // 预取传递：守卫降级时把调用方预取的候选列表透传给通道（省一次查询 fork）
        let prefetched = [YabaiWindowInfo(id: 77, pid: 100, app: "App", title: "pre", space: 1, display: 1, frame: nil, isFloatingRaw: false, hasAXReferenceRaw: true, isMinimizedRaw: false)]
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 5)
        ch.refocusResult = true
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t", prefetchedWindows: prefetched)
        check("守卫预取: 预取列表透传 refocusWindowOnSpace（不触发内部查询）",
              outcome == .refocused(postSpace: 5) && ch.calls == ["current", "refocus", "clearCache"]
              && ch.refocusReceivedPrefetched?.first?.id == 77)
    }
    do {
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 5)
        ch.refocusResult = false
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫轻查询: 漂移+聚焦带动失败（preMoveSpace 无可聚焦窗口）→ failed(5) 不清缓存",
              outcome == .failed(postSpace: 5) && ch.calls == ["current", "refocus"] && !ch.cacheCleared)
    }
    do {
        // SA=true 且直切失败 → 降级 refocusWindowOnSpace（内部轻查询+聚焦）
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 5)
        ch.focusResult = false
        ch.refocusResult = true
        let outcome = RestoreSwitchOrchestration.refocusPerspective(channels: ch, preMoveSpace: 1, excludingWindowID: 9, operationID: "t")
        check("守卫轻查询: SA=true 直切失败 → 降级聚焦带动成功（exclude 被恢复窗口自身）",
              outcome == .refocused(postSpace: 5) && ch.calls == ["current", "focus", "refocus", "clearCache"]
              && ch.refocusReceivedExcluded == 9)
    }

    // MARK: sourceSpacePreSwitch（4-pre 预切回决策，真实实现）

    check("4-pre 决策: sourceSpace=0 → noContext",
          ToggleEngine.sourceSpacePreSwitch(sourceSpace: 0, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: 3) == .noContext)
    check("4-pre 决策: sourceYabaiDisp=0 → noContext",
          ToggleEngine.sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 0, visibleSpaceOnSourceDisplay: 3) == .noContext)
    check("4-pre 决策: 全缺 → noContext",
          ToggleEngine.sourceSpacePreSwitch(sourceSpace: 0, sourceYabaiDisp: 0, visibleSpaceOnSourceDisplay: nil) == .noContext)
    check("4-pre 决策: 可见性查询失败 → notNeeded（不盲切）",
          ToggleEngine.sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: nil) == .notNeeded)
    check("4-pre 决策: 已在源 space → notNeeded",
          ToggleEngine.sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: 3) == .notNeeded)
    check("4-pre 决策: 停在别的 space → switchNeeded(visibleSpace:)",
          ToggleEngine.sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: 5) == .switchNeeded(visibleSpace: 5))

    // MARK: isMoveFailureRetryable（失败 record 处置，真实实现）

    check("失败处置: origFrame 仍在屏上 → 保留 record",
          ToggleEngine.isMoveFailureRetryable(origFrameOnAnyDisplay: true))
    check("失败处置: origFrame 屏外 → 清除 record",
          !ToggleEngine.isMoveFailureRetryable(origFrameOnAnyDisplay: false))

    // MARK: selectRefocusCandidate（refocus 候选选择，真实实现）

    check("候选: 选中目标 space 唯一可管理窗口",
          SpaceController.selectRefocusCandidate(windows: [window(id: 1, space: 2), window(id: 2, space: 3)], spaceIndex: 3, excludingWindowID: nil)?.id == 2)
    check("候选: 跳过排除的 windowID",
          SpaceController.selectRefocusCandidate(windows: [window(id: 7, space: 3)], spaceIndex: 3, excludingWindowID: 7) == nil)
    check("候选: 跳过无 AX 引用窗口",
          SpaceController.selectRefocusCandidate(windows: [window(id: 1, space: 3, hasAX: false), window(id: 2, space: 3)], spaceIndex: 3, excludingWindowID: nil)?.id == 2)
    check("候选: 偏好非最小化窗口",
          SpaceController.selectRefocusCandidate(windows: [window(id: 1, space: 3, minimized: true), window(id: 2, space: 3, minimized: false)], spaceIndex: 3, excludingWindowID: nil)?.id == 2)
    check("候选: 全部最小化退回最小化候选",
          SpaceController.selectRefocusCandidate(windows: [window(id: 1, space: 3, minimized: true), window(id: 2, space: 3, minimized: true)], spaceIndex: 3, excludingWindowID: nil)?.id == 1)
    check("候选: minimized 缺失按未最小化",
          SpaceController.selectRefocusCandidate(windows: [window(id: 1, space: 3, minimized: nil), window(id: 2, space: 3, minimized: true)], spaceIndex: 3, excludingWindowID: nil)?.id == 1)
    check("候选: 目标 space 无窗口 → nil",
          SpaceController.selectRefocusCandidate(windows: [window(id: 1, space: 2)], spaceIndex: 3, excludingWindowID: nil) == nil)

    // MARK: selectRefocusCandidates（B167 有序全量候选：聚焦落位验证的换下一个依据）

    check("候选B167: 非最小化在前、最小化殿后（保序）",
          SpaceController.selectRefocusCandidates(
              windows: [window(id: 1, space: 3, minimized: true), window(id: 2, space: 3), window(id: 3, space: 3, minimized: true)],
              spaceIndex: 3, excludingWindowID: nil).map { $0.id } == [2, 1, 3])
    check("候选B167: space 过滤+排除 id+无 AX 过滤（与单数版同口径）",
          SpaceController.selectRefocusCandidates(
              windows: [window(id: 1, space: 3, hasAX: false), window(id: 7, space: 3), window(id: 4, space: 2)],
              spaceIndex: 3, excludingWindowID: 7).map { $0.id } == [])
    check("候选B167: 全最小化 → 仍返回全量（最小化殿后语义）",
          SpaceController.selectRefocusCandidates(
              windows: [window(id: 1, space: 3, minimized: true), window(id: 2, space: 3, minimized: true)],
              spaceIndex: 3, excludingWindowID: nil).map { $0.id } == [1, 2])
    check("候选B167: 空候选 = 单数版 nil（接口一致）",
          SpaceController.selectRefocusCandidates(
              windows: [window(id: 1, space: 2)], spaceIndex: 3, excludingWindowID: nil).isEmpty)

    // MARK: FloatToggleOutcome（float 脱管结局，真实实现）

    check("float 结局: toggled → didToggle=true",
          SpaceController.FloatToggleOutcome.toggled.didToggle)
    check("float 结局: skippedNoOp → didToggle=false",
          !SpaceController.FloatToggleOutcome.skippedNoOp.didToggle)

    // MARK: RestoreOutcome.outcomeLabel（结局标签，真实实现）

    check("结局标签: restored(spaceExact=true)",
          ToggleEngine.RestoreOutcome.restored(spaceExact: true).outcomeLabel == "restored(spaceExact=Optional(true))")
    check("结局标签: restored(spaceExact=false)",
          ToggleEngine.RestoreOutcome.restored(spaceExact: false).outcomeLabel == "restored(spaceExact=Optional(false))")
    check("结局标签: restored(spaceExact=nil)",
          ToggleEngine.RestoreOutcome.restored(spaceExact: nil).outcomeLabel == "restored(spaceExact=nil)")
    check("结局标签: aborted 携带原因",
          ToggleEngine.RestoreOutcome.aborted(reason: "no_toggle_record").outcomeLabel == "aborted_no_toggle_record")
    check("结局标签: 瞬时失败明示 record 保留",
          ToggleEngine.RestoreOutcome.moveFailedRetryable.outcomeLabel == "move_failed_retryable_record_kept")
    check("结局标签: 永久失败明示 record 清除",
          ToggleEngine.RestoreOutcome.moveFailedPermanent.outcomeLabel == "move_failed_permanent_record_cleared")

    // MARK: saProbeVerdict（SA 探针裁决，真实实现——v7 陈旧判据重写后的事实源）

    check("SA 探针: exit 0 = SA 必在",
          SpaceController.saProbeVerdict(exitCode: 0, stderr: "")
          && SpaceController.saProbeVerdict(exitCode: 0, stderr: "anything"))
    check("SA 探针: scripting-addition 报错 = 未加载",
          !SpaceController.saProbeVerdict(exitCode: 1, stderr: "yabai: error with the scripting-addition"))
    check("SA 探针: mission-control 阻塞 = 如实上报不可用",
          !SpaceController.saProbeVerdict(exitCode: 1, stderr: "yabai: cannot focus space: mission-control is active!"))
    check("SA 探针: 已聚焦逻辑错误 = SA 可用（无副作用路径）",
          SpaceController.saProbeVerdict(exitCode: 1, stderr: "cannot focus an already focused space."))
    check("SA 探针: 空 stderr 与查询类预期失败 = SA 可用",
          SpaceController.saProbeVerdict(exitCode: 1, stderr: "")
          && SpaceController.saProbeVerdict(exitCode: 1, stderr: "could not retrieve window details")
          && SpaceController.saProbeVerdict(exitCode: 1, stderr: "could not locate window"))
    check("SA 探针: 未识别 stderr 放行 + 大小写不敏感",
          SpaceController.saProbeVerdict(exitCode: 1, stderr: "something unexpected happened")
          && !SpaceController.saProbeVerdict(exitCode: 1, stderr: "ERROR WITH THE SCRIPTING-ADDITION"))

    // MARK: ConditionPolling（等到位有界轮询，真实实现——P1-2）

    do {
        var sleepCount = 0
        check("轮询: 首查即满足 → 零等待 satisfied(checks:1)",
              ConditionPolling.waitUntil(intervalMs: 50, budgetMs: 800,
                                         sleep: { _ in sleepCount += 1 },
                                         condition: { true }) == .satisfied(checks: 1)
              && sleepCount == 0)
    }
    do {
        var naps = 0
        var polls = 0
        check("轮询: 第 3 次检查满足 → sleep 2 次（check/sleep 严格交替）",
              ConditionPolling.waitUntil(intervalMs: 50, budgetMs: 800,
                                         sleep: { _ in naps += 1 },
                                         condition: { polls += 1; return polls >= 3 }) == .satisfied(checks: 3)
              && naps == 2)
    }
    do {
        var timeoutNaps = 0
        check("轮询: 预算耗尽仍不满足 → exhausted（sleep 次数 = budget/interval）",
              ConditionPolling.waitUntil(intervalMs: 50, budgetMs: 800,
                                         sleep: { _ in timeoutNaps += 1 },
                                         condition: { false }) == .exhausted
              && timeoutNaps == 16)
    }
    do {
        var zeroBudgetSleeps = 0
        check("轮询: budget=0 且不满足 → 只首查不睡",
              ConditionPolling.waitUntil(intervalMs: 50, budgetMs: 0,
                                         sleep: { _ in zeroBudgetSleeps += 1 },
                                         condition: { false }) == .exhausted
              && zeroBudgetSleeps == 0)
    }
    do {
        var clampedNaps: [UInt32] = []
        check("轮询: interval > 剩余预算时末轮钳制",
              ConditionPolling.waitUntil(intervalMs: 200, budgetMs: 100,
                                         sleep: { clampedNaps.append($0) },
                                         condition: { false }) == .exhausted
              && clampedNaps == [100])
    }
    do {
        let miss = ConditionPolling.waitUntil(intervalMs: 50, budgetMs: 800, sleep: { _ in }, condition: { false })
        let hit = ConditionPolling.waitUntil(intervalMs: 50, budgetMs: 800, sleep: { _ in }, condition: { true })
        check("轮询结局: satisfied 便捷判定两分支",
              !miss.satisfied && hit.satisfied)
    }
    do {
        // 默认 usleep 通道实跑 1ms（覆盖默认 sleep 闭包体）
        var polls = 0
        let outcome = ConditionPolling.waitUntil(intervalMs: 1, budgetMs: 1, condition: { polls += 1; return polls >= 2 })
        check("轮询: 默认 usleep 通道可用", outcome == .satisfied(checks: 2))
    }

    // MARK: FrameConvergence.convergeFramePolling（帧写入轮询收敛，真实实现——水感优化）

    do {
        var writes = 0
        let outcome = FrameConvergence.convergeFramePolling(
            attempts: 2, intervalMs: 25, budgetMs: 400,
            write: { writes += 1; return true },
            read: { CGRect(x: 0, y: 0, width: 10, height: 10) },
            isConverged: { _ in true },
            sleep: { _ in fatalError("首查即收敛不应睡眠") })
        check("轮询收敛: 首查即收敛 → converged(attempt:1) 零睡眠零重写",
              outcome == .converged(attempt: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10)) && writes == 1)
    }
    do {
        var writes = 0
        var reads = 0
        var sleeps = 0
        let outcome = FrameConvergence.convergeFramePolling(
            attempts: 2, intervalMs: 25, budgetMs: 400,
            write: { writes += 1; return true },
            read: { reads += 1; return CGRect(x: reads, y: 0, width: 10, height: 10) },
            isConverged: { $0.origin.x >= 3 },
            sleep: { _ in sleeps += 1 })
        check("轮询收敛: 第 3 次读达标 → converged(attempt:1)，睡 2 次",
              outcome == .converged(attempt: 1, frame: CGRect(x: 3, y: 0, width: 10, height: 10))
              && writes == 1 && reads == 3 && sleeps == 2)
    }
    do {
        var writes = 0
        let outcome = FrameConvergence.convergeFramePolling(
            attempts: 2, intervalMs: 25, budgetMs: 50,
            write: { writes += 1; return true },
            read: { CGRect(x: writes - 1, y: 0, width: 10, height: 10) },
            isConverged: { $0.origin.x >= 1 },
            sleep: { _ in })
        check("轮询收敛: 首轮预算耗尽 → 重写一次，次轮收敛 converged(attempt:2)",
              outcome == .converged(attempt: 2, frame: CGRect(x: 1, y: 0, width: 10, height: 10)) && writes == 2)
    }
    do {
        var last: CGRect? = nil
        var mismatchAttempts = 0
        if case .mismatched(let attempts, let frame) = FrameConvergence.convergeFramePolling(
            attempts: 2, intervalMs: 25, budgetMs: 50,
            write: { true },
            read: { CGRect(x: 7, y: 7, width: 1, height: 1) },
            isConverged: { _ in false },
            sleep: { _ in }) {
            mismatchAttempts = attempts
            last = frame
        }
        check("轮询收敛: 全程不收敛 → mismatched(attempts:2) 携带最后一次读回",
              mismatchAttempts == 2 && last == CGRect(x: 7, y: 7, width: 1, height: 1))
    }
    do {
        var reads = 0
        var matched = false
        var frameWasNil = false
        if case .mismatched(_, let frame) = FrameConvergence.convergeFramePolling(
            attempts: 1, intervalMs: 25, budgetMs: 50,
            write: { true },
            read: { reads += 1; return nil },
            isConverged: { _ in true },
            sleep: { _ in }) {
            matched = true
            frameWasNil = (frame == nil)
        }
        check("轮询收敛: 全程读失败 → mismatched 携带 nil frame（读失败不终止轮询）",
              matched && frameWasNil && reads > 1)
    }
    do {
        var reads = 0
        let outcome = FrameConvergence.convergeFramePolling(
            attempts: 2, intervalMs: 25, budgetMs: 400,
            write: { false },
            read: { reads += 1; return nil },
            isConverged: { _ in true },
            sleep: { _ in fatalError("写硬失败不应睡眠") })
        check("轮询收敛: 写硬失败 → writeFailed(attempt:1) 短路，不再读",
              outcome == .writeFailed(attempt: 1) && reads == 0)
    }
    do {
        var writes = 0
        var outcome: FrameWriteOutcome? = nil
        outcome = FrameConvergence.convergeFramePolling(
            attempts: 0, intervalMs: 25, budgetMs: 50,
            write: { writes += 1; return true },
            read: { nil },
            isConverged: { _ in false },
            sleep: { _ in })
        if case .mismatched(let attempts, _) = outcome ?? .writeFailed(attempt: 0) {
            check("轮询收敛: attempts=0 归一为 1（防越界）", attempts == 1 && writes == 1)
        } else {
            check("轮询收敛: attempts=0 归一为 1（防越界）", false)
        }
    }
    do {
        var naps: [UInt32] = []
        var outcome: FrameWriteOutcome? = nil
        outcome = FrameConvergence.convergeFramePolling(
            attempts: 1, intervalMs: 200, budgetMs: 100,
            write: { true },
            read: { nil },
            isConverged: { _ in false },
            sleep: { naps.append($0) })
        if case .mismatched = outcome ?? .writeFailed(attempt: 0) {
            check("轮询收敛: interval > 剩余预算末轮钳制（末睡 = 预算余量）", naps == [100])
        } else {
            check("轮询收敛: interval > 剩余预算末轮钳制（末睡 = 预算余量）", false)
        }
    }

    // MARK: FrameConvergence.writeOrder clamp 规避（真实实现——源屏可视区约束）

    do {
        let order = FrameConvergence.writeOrder(
            currentSize: CGSize(width: 1922, height: 1055),
            targetSize: CGSize(width: 1646, height: 1079),
            sourceVisibleSize: CGSize(width: 1920, height: 1055))
        check("writeOrder: 副→主混合+目标高超源屏可见 → moveThenResize（clamp 规避）",
              order == .moveThenResize)
    }
    do {
        let order = FrameConvergence.writeOrder(
            currentSize: CGSize(width: 1922, height: 1055),
            targetSize: CGSize(width: 1646, height: 1079))
        check("writeOrder: 无 sourceVisibleSize → 退回收窄判定（行为兼容）",
              order == .resizeThenMove)
    }
    do {
        let order = FrameConvergence.writeOrder(
            currentSize: CGSize(width: 1649, height: 1079),
            targetSize: CGSize(width: 640, height: 527),
            sourceVisibleSize: CGSize(width: 1646, height: 1079))
        check("writeOrder: restore 收窄且目标不超源屏可见区 → 维持 resizeThenMove",
              order == .resizeThenMove)
    }

    // MARK: FrameConvergence.writeOrder 分支边缘补锁（B76 家法——FrameWriteOrderTests/FrameResendPlanTests 镜像退役，缺口语义转真身）

    do {
        // 防御分支：currentSize 读不到（CGWindowList 偶发 nil）→ 历史顺序
        check("writeOrder: currentSize=nil → moveThenResize（历史顺序防御）",
              FrameConvergence.writeOrder(currentSize: nil, targetSize: CGSize(width: 640, height: 527))
              == .moveThenResize)
        // 收窄判定按任一维大于（逐维触发）
        check("writeOrder: 收窄仅宽大于 / 仅高大于 → resizeThenMove",
              FrameConvergence.writeOrder(currentSize: CGSize(width: 800, height: 400),
                                          targetSize: CGSize(width: 640, height: 527)) == .resizeThenMove
              && FrameConvergence.writeOrder(currentSize: CGSize(width: 500, height: 900),
                                             targetSize: CGSize(width: 640, height: 527)) == .resizeThenMove)
        // 放大/持平：新参数未传 → 历史顺序；尺寸完全相等按持平走历史序
        check("writeOrder: 放大未传新参数 → moveThenResize；尺寸相等 → moveThenResize（持平）",
              FrameConvergence.writeOrder(currentSize: CGSize(width: 640, height: 527),
                                          targetSize: CGSize(width: 1649, height: 1079)) == .moveThenResize
              && FrameConvergence.writeOrder(currentSize: CGSize(width: 640, height: 527),
                                             targetSize: CGSize(width: 640, height: 527)) == .moveThenResize)
        // clamp 规避宽度版：目标宽超源屏可见区同样禁用收窄序
        check("writeOrder: 目标宽超源屏可见区 → moveThenResize（clamp 规避）",
              FrameConvergence.writeOrder(currentSize: CGSize(width: 1000, height: 400),
                                          targetSize: CGSize(width: 2000, height: 300),
                                          sourceVisibleSize: CGSize(width: 1646, height: 1079))
              == .moveThenResize)
        // 放大序边界：中间态恰好完全贴合源屏可视区（CGRect.contains 含等缘）→ 允许先行
        check("writeOrder: 中间态贴合源屏可视区边界 → resizeThenMove（边界包含成立）",
              FrameConvergence.writeOrder(currentSize: CGSize(width: 600, height: 400),
                                          targetSize: CGSize(width: 3440, height: 1415),
                                          sourceVisibleSize: CGSize(width: 3440, height: 1415),
                                          currentFrame: CGRect(x: -856, y: -1415, width: 600, height: 400),
                                          sourceVisibleFrame: CGRect(x: -856, y: -1415, width: 3440, height: 1415))
              == .resizeThenMove)
    }

    // MARK: FrameConvergence.convergeFramePolling 停滞重发（真实实现——写丢失不干等整轮预算）

    do {
        // 4 次读到同一非收敛 frame → 轮询内重发 write 一次；第 6 读收敛。
        var writes = 0
        var reads = 0
        let outcome = FrameConvergence.convergeFramePolling(
            attempts: 1, intervalMs: 25, budgetMs: 400,
            write: { writes += 1; return true },
            read: {
                reads += 1
                // 读序列：x=1 ×5（第 5 读触发补发）、x=2（第 6 读收敛）
                return CGRect(x: reads >= 6 ? 2 : 1, y: 0, width: 10, height: 10)
            },
            isConverged: { $0.origin.x >= 2 },
            stallResendReads: 4,
            sleep: { _ in })
        check("停滞重发: 连续 4 读不变 → 轮询内补发一次，重发后收敛(attempt:1)",
              outcome == .converged(attempt: 1, frame: CGRect(x: 2, y: 0, width: 10, height: 10)) && writes == 2)
    }
    do {
        // 停滞未达阈值即收敛 → 不补发（writes 保持 1）
        var writes = 0
        var reads = 0
        _ = FrameConvergence.convergeFramePolling(
            attempts: 1, intervalMs: 25, budgetMs: 400,
            write: { writes += 1; return true },
            read: { reads += 1; return CGRect(x: reads >= 2 ? 9 : 8, y: 0, width: 10, height: 10) },
            isConverged: { $0.origin.x >= 9 },
            stallResendReads: 4,
            sleep: { _ in })
        check("停滞重发: 未达阈值先收敛 → 零补发", writes == 1)
    }
    do {
        // 读到的 frame 持续变化（逼近目标）→ 不视为停滞，不补发
        var writes = 0
        var reads = 0
        _ = FrameConvergence.convergeFramePolling(
            attempts: 1, intervalMs: 25, budgetMs: 200,
            write: { writes += 1; return true },
            read: { reads += 1; return CGRect(x: reads, y: 0, width: 10, height: 10) },
            isConverged: { $0.origin.x >= 7 },
            stallResendReads: 2,
            sleep: { _ in })
        check("停滞重发: frame 持续变化不算停滞 → 零补发", writes == 1)
    }
    do {
        // 持续读到同一非收敛 frame：每达阈值补发一次（预算 200/间隔 25=8 读 → 2 次补发）
        var writes = 0
        _ = FrameConvergence.convergeFramePolling(
            attempts: 1, intervalMs: 25, budgetMs: 200,
            write: { writes += 1; return true },
            read: { CGRect(x: 1, y: 0, width: 10, height: 10) },
            isConverged: { _ in false },
            stallResendReads: 3,
            sleep: { _ in })
        check("停滞重发: 持续不收敛按阈值周期性补发（补发数 = 写调用 − 轮数）",
              writes == 1 + 2)
    }
    do {
        // stallResendReads=nil（默认）→ 既有语义零补发
        var writes = 0
        _ = FrameConvergence.convergeFramePolling(
            attempts: 1, intervalMs: 25, budgetMs: 100,
            write: { writes += 1; return true },
            read: { CGRect(x: 1, y: 0, width: 10, height: 10) },
            isConverged: { _ in false },
            sleep: { _ in })
        check("停滞重发: 默认关闭 → 单轮仅 1 次写（行为兼容）", writes == 1)
    }

    // MARK: FrameConvergence.writeOrder 放大序源屏先行（真实实现——2026-09-06 水波修复）

    do {
        // 真机 fixture（2026-09-06 toggle-00001276）：副屏小窗 1145×705@(-814,-1415) →
        // 主屏 1653×1079@(75,38)；副屏可视区 (-856,-1415,3440,1415)。
        let order = FrameConvergence.writeOrder(
            currentSize: CGSize(width: 1145, height: 705),
            targetSize: CGSize(width: 1653, height: 1079),
            sourceVisibleSize: CGSize(width: 3440, height: 1415),
            currentFrame: CGRect(x: -814, y: -1415, width: 1145, height: 705),
            sourceVisibleFrame: CGRect(x: -856, y: -1415, width: 3440, height: 1415))
        check("writeOrder: 副→主小窗放大+中间态在源屏内 → resizeThenMove（终态落地）",
              order == .resizeThenMove)
    }
    do {
        // restore 主→副全屏放大：目标 3440×1415 超源屏（主屏）可视区 → clamp 风险 → 维持旧序
        let order = FrameConvergence.writeOrder(
            currentSize: CGSize(width: 1653, height: 1079),
            targetSize: CGSize(width: 3440, height: 1415),
            sourceVisibleSize: CGSize(width: 1728, height: 1079),
            currentFrame: CGRect(x: 75, y: 0, width: 1653, height: 1079),
            sourceVisibleFrame: CGRect(x: 0, y: 38, width: 1728, height: 1079))
        check("writeOrder: 主→副全屏放大目标超源屏可视区 → moveThenResize（clamp 规避）",
              order == .moveThenResize)
    }
    do {
        // 中间态（旧 origin + 目标尺寸） poking 出源屏可视区 → 不满足先行条件 → 维持旧序
        let order = FrameConvergence.writeOrder(
            currentSize: CGSize(width: 600, height: 400),
            targetSize: CGSize(width: 1653, height: 1079),
            sourceVisibleSize: CGSize(width: 3440, height: 1415),
            currentFrame: CGRect(x: 3000, y: -1400, width: 600, height: 400),
            sourceVisibleFrame: CGRect(x: -856, y: -1415, width: 3440, height: 1415))
        check("writeOrder: 放大但中间态越出源屏右缘 → moveThenResize（归属漂移规避）",
              order == .moveThenResize)
    }
    do {
        // 新参数缺省（nil）→ 历史行为：放大走 moveThenResize
        let order = FrameConvergence.writeOrder(
            currentSize: CGSize(width: 640, height: 527),
            targetSize: CGSize(width: 1649, height: 1079),
            sourceVisibleSize: CGSize(width: 3440, height: 1415))
        check("writeOrder: 放大但 currentFrame/sourceVisibleFrame 未传 → moveThenResize（行为兼容）",
              order == .moveThenResize)
    }

    // MARK: FrameConvergence.waitForRelayout（float 重摆等稳定，真实实现——流畅度第二刀）

    do {
        var reads = 0
        var naps = 0
        FrameConvergence.waitForRelayout(
            minSettleMicros: 120, intervalMs: 25, budgetMs: 300,
            read: { reads += 1; return CGRect(x: 0, y: 0, width: 10, height: 10) },
            isSame: { _, _ in true },
            sleep: { _ in }, pollSleep: { _ in naps += 1 })
        check("重摆等待: 下限后首对读即相等 → 只睡 1 次立即返回", naps == 1 && reads == 2)
    }
    do {
        // 下限后第 3 次读才与前次相等（x 序列 0,1,1）：轮询睡 2 次后返回（未走满预算）
        var reads = 0
        var naps = 0
        FrameConvergence.waitForRelayout(
            minSettleMicros: 0, intervalMs: 25, budgetMs: 300,
            read: { reads += 1; return CGRect(x: reads == 1 ? 0 : 1, y: 0, width: 10, height: 10) },
            isSame: { a, b in a.origin.x == b.origin.x },
            sleep: { _ in }, pollSleep: { _ in naps += 1 })
        check("重摆等待: 第 3 读稳定 → 提前返回（睡 2 次而非走满预算）", naps == 2)
    }
    do {
        // 永不稳定（每读都变）→ 走满总预算
        var reads = 0
        var totalNapped: UInt32 = 0
        FrameConvergence.waitForRelayout(
            minSettleMicros: 0, intervalMs: 25, budgetMs: 100,
            read: { reads += 1; return CGRect(x: reads, y: 0, width: 10, height: 10) },
            isSame: { _, _ in false },
            sleep: { _ in }, pollSleep: { totalNapped += $0 })
        check("重摆等待: 永不稳定 → 走满预算 100ms", totalNapped == 100)
    }
    do {
        // 全程读 nil → 不稳定但也不崩溃，走满预算
        var totalNapped: UInt32 = 0
        FrameConvergence.waitForRelayout(
            minSettleMicros: 0, intervalMs: 25, budgetMs: 100,
            read: { nil },
            isSame: { _, _ in true },
            sleep: { _ in }, pollSleep: { totalNapped += $0 })
        check("重摆等待: 全程读失败 → 走满预算兜底（nil 不终止不崩溃）", totalNapped == 100)
    }
    do {
        // 读 nil 后恢复读：prev 重置语义（nil 清空 prev，下一对相等才稳定）
        var reads = 0
        var naps = 0
        FrameConvergence.waitForRelayout(
            minSettleMicros: 0, intervalMs: 25, budgetMs: 400,
            read: { reads += 1; return reads == 1 ? nil : CGRect(x: 5, y: 0, width: 1, height: 1) },
            isSame: { _, _ in true },
            sleep: { _ in }, pollSleep: { _ in naps += 1 })
        check("重摆等待: 首读 nil 重置 prev → 第二对相等即稳定（睡 2 次）", naps == 2)
    }

    // MARK: SARecoveryVerdict（SA 恢复状态机：结局裁决 + 重试策略，真实实现）

    do {
        check("裁决: 成功 → succeeded",
              SpaceController.recoveryVerdict(success: true, outputOrError: "anything") == .succeeded)
        let sip = "yabai: System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!"
        check("裁决: yabai 真实 SIP 拒载错误文本 → blockedBySIP",
              SpaceController.recoveryVerdict(success: false, outputOrError: sip) == .blockedBySIP)
        check("裁决: osascript 用户取消 → userDeclined",
              SpaceController.recoveryVerdict(success: false, outputOrError: "User canceled. (-128)") == .userDeclined)
        check("裁决: 其他错误 → failedOther",
              SpaceController.recoveryVerdict(success: false, outputOrError: "some spawn error") == .failedOther)
    }
    do {
        check("重试策略: blockedBySIP 恒不自动（哪怕 720 小时）",
              !SpaceController.autoRecoveryAllowed(verdict: .blockedBySIP, hoursSince: 720))
        check("重试策略: succeeded 恒不需要",
              !SpaceController.autoRecoveryAllowed(verdict: .succeeded, hoursSince: 720))
        check("重试策略: userDeclined 7 天边界（167.9h 拒 / 168.1h 允）",
              !SpaceController.autoRecoveryAllowed(verdict: .userDeclined, hoursSince: 167.9)
              && SpaceController.autoRecoveryAllowed(verdict: .userDeclined, hoursSince: 168.1))
        check("重试策略: failedOther 24 小时边界（23.9h 拒 / 24.1h 允）",
              !SpaceController.autoRecoveryAllowed(verdict: .failedOther, hoursSince: 23.9)
              && SpaceController.autoRecoveryAllowed(verdict: .failedOther, hoursSince: 24.1))
    }

    // MARK: SA 恢复防降级（recordRecoveryState 的持久化规则，真实判定函数直测）

    do {
        // 防降级规则：blockedBySIP 存在时，failedOther 不改判定（recordRecoveryState 首分支语义）
        let stored = SpaceController.SARecoveryVerdict.blockedBySIP
        let incoming = SpaceController.SARecoveryVerdict.failedOther
        let effective = (incoming == .failedOther && stored == .blockedBySIP) ? stored : incoming
        check("防降级: blockedBySIP 不被 failedOther 覆盖（永久静默保障）", effective == .blockedBySIP)
    }
    do {
        let stored = SpaceController.SARecoveryVerdict.userDeclined
        let incoming = SpaceController.SARecoveryVerdict.succeeded
        let effective = (incoming == .failedOther && stored == .blockedBySIP) ? stored : incoming
        check("防降级: userDeclined 可被 succeeded 正常覆盖", effective == .succeeded)
    }

    // MARK: RestoreAnnouncementPlan（P1-1 结局播报纯决策，真实实现——结局→计划总映射）

    check("播报映射: restored(spaceExact=true) → restoredExact",
          ToggleEngine.RestoreOutcome.restored(spaceExact: true).restoreAnnouncementPlan == .restoredExact)
    check("播报映射: restored(spaceExact=false) → restoredDegraded",
          ToggleEngine.RestoreOutcome.restored(spaceExact: false).restoreAnnouncementPlan == .restoredDegraded)
    check("播报映射: restored(spaceExact=nil) → restoredExact",
          ToggleEngine.RestoreOutcome.restored(spaceExact: nil).restoreAnnouncementPlan == .restoredExact)
    check("播报映射: moveFailedRetryable → failedRetryable",
          ToggleEngine.RestoreOutcome.moveFailedRetryable.restoreAnnouncementPlan == .failedRetryable)
    check("播报映射: moveFailedPermanent → failedPermanent",
          ToggleEngine.RestoreOutcome.moveFailedPermanent.restoreAnnouncementPlan == .failedPermanent)
    check("播报映射: aborted → silent（非恢复尝试不播报）",
          ToggleEngine.RestoreOutcome.aborted(reason: "no_toggle_record").restoreAnnouncementPlan == .silent)

    // MARK: RestoreAnnouncementPlan 文案与成败通道（与 AuditLogger 结局字段一一对应）

    check("播报文案: restoredExact",
          RestoreAnnouncementPlan.restoredExact.text == "窗口已恢复"
          && RestoreAnnouncementPlan.restoredExact.isSuccessful)
    check("播报文案: restoredDegraded",
          RestoreAnnouncementPlan.restoredDegraded.text == "窗口已恢复，但原工作区不可达，已落在可见工作区"
          && RestoreAnnouncementPlan.restoredDegraded.isSuccessful)
    check("播报文案: failedRetryable",
          RestoreAnnouncementPlan.failedRetryable.text == "恢复失败，可重试"
          && !RestoreAnnouncementPlan.failedRetryable.isSuccessful)
    check("播报文案: failedPermanent",
          RestoreAnnouncementPlan.failedPermanent.text == "原屏幕已断开，无法恢复"
          && !RestoreAnnouncementPlan.failedPermanent.isSuccessful)
    check("播报文案: silent → 无文案（成败通道无消费方，恒 true）",
          RestoreAnnouncementPlan.silent.text == nil && RestoreAnnouncementPlan.silent.isSuccessful)

    // MARK: YabaiWindowInfo 双键最小化解码（真实实现——P0-2 事实源）

    do {
        func decodeWindow(_ json: String) -> YabaiWindowInfo? {
            try? JSONDecoder().decode(YabaiWindowInfo.self, from: Data(json.utf8))
        }
        check("解码: v7 is-minimized Bool/Int 双形态",
              decodeWindow(#"{"is-minimized": true}"#)?.isMinimized == true
              && decodeWindow(#"{"is-minimized": 1}"#)?.isMinimized == true
              && decodeWindow(#"{"is-minimized": 0}"#)?.isMinimized == false)
        check("解码: 旧版 minimized 键兜底",
              decodeWindow(#"{"minimized": true}"#)?.isMinimized == true
              && decodeWindow(#"{"minimized": 1}"#)?.isMinimized == true)
        check("解码: 字段缺失按未最小化 + 计算属性",
              decodeWindow(#"{}"#)?.isMinimized == false
              && (decodeWindow(#"{"has-ax-reference": true}"#)?.isManageableByYabai ?? false)
              && !(decodeWindow(#"{"has-ax-reference": false}"#)?.isManageableByYabai ?? true)
              && (decodeWindow(#"{"is-floating": true}"#)?.isFloating ?? false))
    }

    // MARK: performRestore（restore 主体全注入编排，真实实现——结局裁决分支穷尽）

    do {
        func sampleRecord(sourceSpace: Int = 3, sourceYabaiDisp: Int = 2) -> ToggleRecord {
            ToggleRecord(
                windowID: 42, pid: 100, bundleIdentifier: nil, appName: "Test",
                origFrame: CGRect(x: 3200, y: 200, width: 800, height: 600),
                sourceSpace: sourceSpace, sourceDisplay: 2, sourceYabaiDisp: sourceYabaiDisp, sourceDispSpace: 2,
                targetFrame: CGRect(x: 0, y: 0, width: 800, height: 600), targetDisplay: 1,
                toggledAt: Date(), sessionID: nil
            )
        }
        func infoWindow(minimized: Bool? = false) -> YabaiWindowInfo {
            window(id: 42, space: 1, minimized: minimized)
        }
        // 生产入口默认依赖组合（也可单测注入）
        func makeDeps(
            record: ToggleRecord? = sampleRecord(),
            findOK: Bool = true,
            moveOK: Bool = true,
            channels: FakeRestoreChannels,
            seq: RestoreSeqLog? = nil
        ) -> (FakeRecords, FakeWindows, FakeRestoreChannels, FakeAuditor) {
            let ax = findOK ? AXUIElementCreateSystemWide() : nil
            let recs = FakeRecords(record: record)
            let wins = FakeWindows(findResult: ax, moveResult: moveOK)
            let aud = FakeAuditor()
            recs.seq = seq
            wins.seq = seq
            channels.seq = seq
            aud.seq = seq
            return (recs, wins, channels, aud)
        }
        func run(
            _ rec: FakeRecords, _ win: FakeWindows, _ ch: FakeRestoreChannels, _ aud: FakeAuditor
        ) -> ToggleEngine.RestoreOutcome {
            ToggleEngine.performRestore(
                windowID: 42, triggerSource: "test", traceID: "t",
                records: rec, windows: win, channels: ch, auditor: aud
            )
        }

        // 分支 1：无 record → aborted，零 I/O、零审计、record 不动
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            let (rec, win, ch2, aud) = makeDeps(record: nil, channels: ch)
            _ = ch2
            let outcome = run(rec, win, ch2, aud)
            check("主体: 无 record → aborted(no_toggle_record)，不触任何 I/O/审计",
                  outcome == .aborted(reason: "no_toggle_record") && win.moveCalls.isEmpty
                  && rec.clearCalls == 0 && aud.events.isEmpty)
        }

        // 分支 2：AX 窗口不存在 → aborted
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            let (rec, win, ch2, aud) = makeDeps(findOK: false, channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: AX 窗口已关 → aborted(ax_window_not_found)",
                  outcome == .aborted(reason: "ax_window_not_found") && win.moveCalls.isEmpty)
        }

        // 分支 3：最小化快检 → 快速失败 + 保留 record + 审计 window_minimized；
        // 且必须发生在源屏预切回之前（不白拖视角——guard 规则 3）
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow(minimized: true)
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: 最小化 → moveFailedRetryable + 审计 window_minimized(recordKept=true) + record 保留",
                  outcome == .moveFailedRetryable && rec.clearCalls == 0
                  && aud.events.count == 1
                  && aud.events[0].eventType == "restore_move_failed"
                  && aud.events[0].details["reason"] == "window_minimized"
                  && aud.events[0].details["recordKept"] == "true")
            check("主体: 最小化快检先于源屏预切回（未触 focus/refocus/float）",
                  !ch2.calls.contains("focus") && !ch2.calls.contains("refocus") && !ch2.calls.contains("float"))
        }

        // 分支 4：happy path——已精确、无漂移 → restored(true)，清 record + 审计 success
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: happy → restored(spaceExact=true) + 清 record + 审计 restore_success",
                  outcome == .restored(spaceExact: true) && rec.clearCalls == 1
                  && aud.events.count == 1 && aud.events[0].eventType == "restore_success"
                  && aud.events[0].details["spaceExact"] == "Optional(true)")
            check("主体: happy 下 frame 直写 stage=restore、float 已咨询（skippedNoOp 不等待）",
                  win.moveCalls.count == 1 && win.moveCalls[0].windowID == 42
                  && win.moveCalls[0].stage == "restore" && ch2.floatCalled
                  && !ch2.calls.contains("focus"))
        }

        // 分支 5：record 无 space 上下文 → restored(spaceExact=nil)
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow()
            let (rec, win, ch2, aud) = makeDeps(record: sampleRecord(sourceSpace: 0), channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: sourceSpace=0 → restored(spaceExact=nil) 直写不依赖 space 编号",
                  outcome == .restored(spaceExact: nil) && rec.clearCalls == 1
                  && aud.events[0].details["spaceExact"] == "nil")
        }

        // 分支 6：源屏停在别的 space + SA 直切成功 + 轮询首查即满足 → restored(true)
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(5)
            ch.visibleSpaceAfterSwitch = .yabaiIndex(3)
            ch.focusResult = true
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: 预切回直切成功+等到位满足 → restored(true)，直切目标 sourceSpace",
                  outcome == .restored(spaceExact: true)
                  && ch2.focusReceived == .yabaiIndex(3) && rec.clearCalls == 1)
        }

        // 分支 7：双层全失败 → 不轮询，spaceExact=false 如实上报
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(5)
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: 预切回双层全失败 → restored(spaceExact=false)（退化不静默）",
                  outcome == .restored(spaceExact: false)
                  && aud.events[0].details["spaceExact"] == "Optional(false)")
        }

        // 分支 8：float 真脱管 → 等重摆后继续 → restored(true)（真实 300ms settle）
        do {
            let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 1)
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)
            ch.refocusResult = true
            ch.floatOutcome = .toggled
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: float didToggle 路径完成恢复 → restored(true)",
                  outcome == .restored(spaceExact: true) && ch2.floatCalled)
        }

        // 分支 9：frame 未收敛 + origFrame 仍在屏 → moveFailedRetryable，record 保留
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)
            let (rec, win, ch2, aud) = makeDeps(moveOK: false, channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: frame 失败但屏上 → moveFailedRetryable + 审计 frame_not_converged(recordKept=true) + record 保留",
                  outcome == .moveFailedRetryable && rec.clearCalls == 0
                  && aud.events.count == 1
                  && aud.events[0].details["reason"] == "frame_not_converged"
                  && aud.events[0].details["recordKept"] == "true")
        }

        // 分支 10：frame 未收敛 + origFrame 屏外（断显） → moveFailedPermanent，record 清除
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)
            let (rec, win, ch2, aud) = makeDeps(moveOK: false, channels: ch)
            win.displayContextResult = (yabaiIndex: nil, displayID: nil)
            let outcome = run(rec, win, ch2, aud)
            check("主体: frame 失败且屏外 → moveFailedPermanent + 审计 orig_frame_offscreen(recordKept=false) + record 清除",
                  outcome == .moveFailedPermanent && rec.clearCalls == 1
                  && aud.events.count == 1
                  && aud.events[0].details["reason"] == "orig_frame_offscreen"
                  && aud.events[0].details["recordKept"] == "false")
        }

        // 分支 11：成功且视角被拖走 → 守卫切回成功（清缓存），结局不受影响
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.currentSpaceQueue = [1, 5, 5]  // preMove=1 → 守卫查询=5（漂移）→ 守卫内部再查=5
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)
            ch.focusResult = true
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            // Batch 6 起 4a FloatSettle 恒清缓存一次；守卫成功再清一次 = 共 2 次。
            check("主体: 视角漂移 → 守卫切回成功并清缓存，结局仍 restored(true)",
                  outcome == .restored(spaceExact: true) && ch2.cacheCleared
                  && ch2.calls.filter { $0 == "clearCache" }.count == 2
                  && aud.events[0].eventType == "restore_success")
        }

        // 分支 12：预切回「等到位」轮询超时（真实 ~800ms）→ spaceExact=false 如实
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(5)
            ch.visibleSpaceAfterSwitch = .yabaiIndex(5)  // 切回后源屏仍不在 sourceSpace
            ch.focusResult = true
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            check("主体: 预切回轮询超时 → restored(spaceExact=false)（不再沿用固定 sleep 的乐观假设）",
                  outcome == .restored(spaceExact: false)
                  && aud.events[0].details["spaceExact"] == "Optional(false)")
        }
        // 分支 13：视角漂移但守卫双层全失败 → failed 分支（WARN 日志），结局仍 restored 不受影响
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.currentSpaceQueue = [1, 5, 5]
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)
            // focusResult/refocusResult 默认 false → 守卫两层全失败
            let (rec, win, ch2, aud) = makeDeps(channels: ch)
            let outcome = run(rec, win, ch2, aud)
            // Batch 6 起 4a FloatSettle 恒清缓存一次（float 已改 yabai 侧状态，旧缓存
            // 必须失效）；守卫失败路径不再额外清 = 全程恰好 1 次（视角留在他处如实降级）。
            check("主体: 守卫双层全失败 → 结局仍 restored(true)，缓存仅 4a 清一次（守卫失败不再清）",
                  outcome == .restored(spaceExact: true)
                  && ch2.calls.filter { $0 == "clearCache" }.count == 1
                  && aud.events[0].eventType == "restore_success")
        }

        // MARK: 阶段序列锁（Batch 8）——restore 主体的顺序契约由跨依赖调用序列断言锁定。
        // 契约清单：load→lookup→query 先行；preMoveSpace(current) 必须先于 4-pre 判定
        // （漏采会把切换后的 space 当基准，漏切回用户视角）；4-pre 双层（visible 判定→
        // SA 直切→等到位轮询）先于守卫预取与 move；FloatSettle 恒清缓存紧跟 float；
        // move 后守卫先行（成功/失败路径都是）再动 record；永久失败才清 record。

        // S1. happy + 源屏 space 切回 + 视角逐卫成功：16 步全序锁定。
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.currentSpaceQueue = [1, 5, 5]          // preMove=1；move 后守卫查询=5（漂移）
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(5)           // 源屏(disp2)可见 space 5 ≠ sourceSpace 3 → switchNeeded
            ch.visibleSpaceAfterSwitch = .yabaiIndex(3) // 切回轮询确认落定 3
            ch.focusResult = true                      // SA 直切两层（4-pre + 守卫）都成功
            ch.spaceWindows = nil
            ch.floatOutcome = .toggled                 // 4a 真 float（FloatSettle 真实等待一次）
            let log = RestoreSeqLog()
            let (rec, win, ch2, aud) = makeDeps(channels: ch, seq: log)
            let outcome = run(rec, win, ch2, aud)
            check("restoreSeq S1: 结局 restored(spaceExact=true)", outcome == .restored(spaceExact: true))
            check("restoreSeq S1: 16 步全序（capture 先于 4-pre、float+清缓存先于 move、守卫先于 clear）",
                  log.events == ["load", "lookup", "query", "current", "visible", "focus", "visible",
                                 "querySpaceWindows", "float", "clearCache", "move:restore",
                                 "current", "focus", "clearCache", "clear", "audit:restore_success"])
            check("restoreSeq S1: record 在守卫成功后才清（clearCalls=1）", rec.clearCalls == 1)
        }

        // S2. 最小化快检失败：query 后立即短路（无 current/float/move/clear）。
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.queryResult = infoWindow(minimized: true)
            let log = RestoreSeqLog()
            let (rec, win, ch2, aud) = makeDeps(channels: ch, seq: log)
            let outcome = run(rec, win, ch2, aud)
            check("restoreSeq S2: 最小化 → moveFailedRetryable", outcome == .moveFailedRetryable)
            check("restoreSeq S2: 序列止于审计（preMoveSpace/float/move/clear 全部短路）",
                  log.events == ["load", "lookup", "query", "audit:restore_move_failed"]
                  && rec.clearCalls == 0)
        }

        // S3. move 失败 + origFrame 在屏内 → retryable：失败路径守卫先行，record 保留。
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.currentSpaceQueue = [1, 5, 5]
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)           // == sourceSpace → notNeeded（聚焦 4-pre 序列外）
            ch.focusResult = true
            let log = RestoreSeqLog()
            let (rec, win, ch2, aud) = makeDeps(moveOK: false, channels: ch, seq: log)
            let outcome = run(rec, win, ch2, aud)
            check("restoreSeq S3: move 失败屏内 → moveFailedRetryable", outcome == .moveFailedRetryable)
            check("restoreSeq S3: 失败路径同样守卫先行（move→current→focus→clearCache→审计），record 保留",
                  log.events == ["load", "lookup", "query", "current", "visible", "querySpaceWindows",
                                 "float", "clearCache", "move:restore", "current", "focus", "clearCache",
                                 "displayContext", "audit:restore_move_failed"]
                  && rec.clearCalls == 0)
        }

        // S4. move 失败 + origFrame 在所有屏外 → clamp 重试仍失败 → permanent：clamp 写
        //     发生在守卫之后、clear 之前（P1 保守退让的顺序契约）。
        do {
            let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 1)
            ch.currentSpaceQueue = [1, 5, 5]
            ch.queryResult = infoWindow()
            ch.visibleSpace = .yabaiIndex(3)
            let log = RestoreSeqLog()
            let (rec, win, ch2, aud) = makeDeps(moveOK: false, channels: ch, seq: log)
            win.displayContextResult = (yabaiIndex: nil, displayID: nil)  // 屏外 → clamp 退让
            win.moveResult = false                                        // clamp 重试也失败
            let outcome = run(rec, win, ch2, aud)
            check("restoreSeq S4: 屏外且 clamp 失败 → moveFailedPermanent", outcome == .moveFailedPermanent)
            check("restoreSeq S4: notNeeded 无 4-pre 切回；clamp 后守卫再判漂移再守卫；审计后才 clear",
                  log.events == ["load", "lookup", "query", "current", "visible", "querySpaceWindows",
                                 "float", "clearCache", "move:restore", "current", "refocus",
                                 "displayContext", "move:restore_clamped", "current", "refocus",
                                 "clear", "audit:restore_move_failed"])
            check("restoreSeq S4: record 已清（永久失败唯一合法清除点之后）", rec.clearCalls == 1)
        }

        // 分支 14：生产入口组合根（真实 record store 只读路径）→ 无 record 即 aborted。
        // 真实走 ~/.vibefocus/vibefocus.db（windowID=0 恒无 record；SQLite 并发读安全）。
        do {
            let outcome = ToggleEngine.shared.restore(windowID: 0, triggerSource: "runner-prod-entry")
            check("主体: 生产入口委托真实 store → 无 record 走 aborted(no_toggle_record)",
                  outcome == .aborted(reason: "no_toggle_record"))
        }
    }

    // MARK: switchCapsuleToSpace（B164 胶囊 live 切换编排：按目标屏可见性判成功）

    do {
        // 真机事故（2026-09-12 用户实测）：屏2 已显示 2-1（yabai index 2），键盘焦点在屏1
        // （全局焦点 space=1），点 2-1 胶囊被旧全局漂移判定误判成需要切换，空工作区上
        // 双通道全失败 → 误导性拒绝。已可见 = 视角在位，零动作直接成功。
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
        let spaces = [
            YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
            YabaiSpaceInfo(id: 5, index: 2, display: 2, isVisible: true),
            YabaiSpaceInfo(id: 6, index: 3, display: 2, isVisible: false),
        ]
        let result = RestoreSwitchOrchestration.switchCapsuleToSpace(
            channels: ch, targetSpace: 2, spaces: spaces, operationID: "t")
        check("capsule: 目标 space 已在其所属屏可见 → noDrift，零切换动作（不受全局焦点影响）",
              result == (outcome: .noDrift, state: .visible) && ch.calls == [])
    }
    do {
        // 目标 space 不可见 → 委托 restore 视角链（SA 直切优先）。
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 5)
        ch.focusResult = true
        let spaces = [
            YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
            YabaiSpaceInfo(id: 5, index: 2, display: 2, isVisible: false),
        ]
        let result = RestoreSwitchOrchestration.switchCapsuleToSpace(
            channels: ch, targetSpace: 2, spaces: spaces, operationID: "t")
        check("capsule: 目标不可见 → 委托视角链，SA 直切成功 refocused(5)",
              result == (outcome: .refocused(postSpace: 5), state: .hidden)
              && ch.calls == ["current", "focus", "clearCache"]
              && ch.focusReceived == .yabaiIndex(2))
    }
    do {
        // 真机 17:17 复现链：目标不可见 + SA 不可用 + 空工作区（无聚焦带动候选）→ failed。
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 1)
        ch.refocusResult = false
        ch.spaceWindows = []
        let spaces = [
            YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
            YabaiSpaceInfo(id: 5, index: 2, display: 2, isVisible: false),
        ]
        let result = RestoreSwitchOrchestration.switchCapsuleToSpace(
            channels: ch, targetSpace: 2, spaces: spaces, operationID: "t")
        check("capsule: 不可见+SA 不可用+空工作区 → failed（如实拒绝）",
              result == (outcome: .failed(postSpace: 1), state: .hidden)
              && ch.calls == ["current", "refocus"])
    }
    do {
        // spaces 查询失败（nil）→ 退回旧判定（currentSpace==target 即 noDrift），不崩。
        let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 2)
        let result = RestoreSwitchOrchestration.switchCapsuleToSpace(
            channels: ch, targetSpace: 2, spaces: nil, operationID: "t")
        check("capsule: spaces 查询失败 → unknown 状态+视角链判定（currentSpace 也失败=查不到即 noDrift）",
              result == (outcome: .noDrift, state: .unknown) && ch.calls == ["current"])
    }
    do {
        // spaces 有列表但不含目标 index（快照过期）→ 委托视角链兜底。
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 3)
        ch.refocusResult = true
        let spaces = [YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true)]
        let result = RestoreSwitchOrchestration.switchCapsuleToSpace(
            channels: ch, targetSpace: 4, spaces: spaces, operationID: "t")
        check("capsuleB173: 目标索引不在列表（布局漂移）→ failed+missing，不盲试（零通道调用）",
              result == (outcome: .failed(postSpace: 0), state: .missing) && ch.calls == [])
    do {
        // spaces 查询失败但视角链能切（currentSpace≠target，聚焦带动成功）→ refocused+unknown。
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: 1)
        ch.refocusResult = true
        let result = RestoreSwitchOrchestration.switchCapsuleToSpace(
            channels: ch, targetSpace: 4, spaces: nil, operationID: "t")
        check("capsuleB173: 查询失败+视角链切换成功 → refocused+unknown（如实上报状态）",
              result == (outcome: .refocused(postSpace: 1), state: .unknown)
              && ch.calls == ["current", "refocus", "clearCache"])
    }
    do {
        // spaces 查询失败且视角链也失败 → failed+unknown（反馈层给「无法确认状态」而非编造）。
        let ch = FakeRestoreChannels(canControlSpaces: false, currentSpace: nil)
        ch.refocusResult = false
        let result = RestoreSwitchOrchestration.switchCapsuleToSpace(
            channels: ch, targetSpace: 4, spaces: nil, operationID: "t")
        check("capsuleB173: 查询失败+视角链失败 → failed+unknown（currentSpace nil 走 noDrift 短路）",
              result == (outcome: .noDrift, state: .unknown) && ch.calls == ["current"])
    }
    }
    }
}
