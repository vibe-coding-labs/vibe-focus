import Foundation
import CoreGraphics

/// 「float 脱管 → 等重摆落定 → 查询缓存失效」唯一序列原语（Batch 6）。
///
/// ## 为什么存在
/// 该序列此前在 5 处手抄（Layout.floatAndWriteFrame、move_to_main P2、
/// move_to_main AX 路径、stuck 解堵、restore 4a），语义已经漂移：
/// - 等待策略两档：4 处走 waitForRelayout 等稳定轮询（2026-09-03 流畅度第二刀），
///   restore 4a 还是固定 usleep 300ms（历史档）——同一次 float 脱管，两条路径
///   的落定保证不同源，改一处漏四处的活体样本；
/// - 缓存失效三档：仅 toggle 后清（Layout）/ 恒清（P2、stuck）/ 从不清
///   （AX 路径、restore）——float 已改变 yabai 侧 isFloating/frame，漏清的
///   下游 queryWindow 吃到 float 前旧值，是竞态温床。
///
/// ## 序列契约（Tests/Standalone/FloatSettleSequenceTests 镜像 + Runner 真身双锁）
/// 1. setFloat 恰好调一次：knownWindowInfo 透传（nil 时由通道内部查询，fork 数
///    不变）；已 float / unmanaged / disabled 的跳过决策在通道内纯函数完成
///    （SpaceController.floatToggleDecision），本原语不重复判定；
/// 2. 仅真 toggle 后等重摆：FrameConvergence.waitForRelayout——先睡
///    floatRelayoutMinSettleMicros 下限（防重摆未启动的静默假稳定），再按
///    frameVerifyPollIntervalMs 轮询 frame 稳定早返回，floatRelayoutSettleMicros
///    总预算兜底（2026-09-01 尺寸错乱根因：等待不足写被重摆覆盖）；
/// 3. 查询缓存无条件失效（统一语义，取五处中最安全档）：清除是内存字典清空
///    零成本；跳过场景缓存虽未变脏，恒清省掉「哪些路径变了状态」的推理负担。
///
/// 全链路无 AX 依赖（yabai fork + CGWindowList 读 + 内存清缓存），可在无辅助
/// 功能授权环境真机闭环验证。
enum FloatSettle {

    struct Outcome: Equatable {
        /// 真发生了 --toggle float（yabai 默认重摆已被等待落定）。
        let didToggle: Bool
        /// float 决策 + （如有）重摆等待的总耗时。
        let durationMs: Int
    }

    static func floatAndSettle(
        windowID: UInt32,
        operationID: String,
        knownWindowInfo: YabaiWindowInfo?,
        tolerance: CGFloat,
        setFloat: (UInt32, String, YabaiWindowInfo?) -> SpaceController.FloatToggleOutcome,
        read: (UInt32) -> CGRect?,
        clearCache: () -> Void,
        sleep: (useconds_t) -> Void = { usleep($0) },
        pollSleep: (UInt32) -> Void = { usleep(useconds_t($0) * 1_000) }
    ) -> Outcome {
        let startedAt = Date()
        let outcome = setFloat(windowID, operationID, knownWindowInfo)
        if outcome.didToggle {
            FrameConvergence.waitForRelayout(
                minSettleMicros: WindowSettle.floatRelayoutMinSettleMicros,
                intervalMs: WindowSettle.frameVerifyPollIntervalMs,
                // μs→ms 换算：floatRelayoutSettleMicros 是微秒（300_000），waitForRelayout
                // 的 budgetMs 形参以毫秒计。Batch 6 前的四处手抄均直传微秒值（=300_000ms
                // 预算），「frame 永不稳定」病理路径下轮询 30 万拍 × 25ms ≈ 100 分钟
                // 挂死热键——镜像测试 C 场景逮出，修正为其文档契约（下限+预算 ≤ 420ms）。
                budgetMs: UInt32(WindowSettle.floatRelayoutSettleMicros / 1_000),
                read: { read(windowID) },
                isSame: { CoordinateKit.isFrameConverged(actual: $1, target: $0, tolerance: tolerance) },
                sleep: sleep,
                pollSleep: pollSleep
            )
        }
        clearCache()
        return Outcome(didToggle: outcome.didToggle, durationMs: elapsedMilliseconds(since: startedAt))
    }
}
