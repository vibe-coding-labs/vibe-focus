import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - AX 写入编排层（2026-08-31 从 +AXHelpers.swift 拆分，行为不变）
// apply 两阶段（Phase 1 size + Phase 2 position）frame 写入及其子步骤。读取原语见 +AXRead.swift。

@MainActor
extension WindowManager {

    /// 写入目标 frame。两阶段固定顺序：Phase 1 size write + readback retry，Phase 2 position write。
    /// phase1Ms/phase2Ms 即 size 阶段 / position 阶段耗时。
    ///
    /// ## 场景
    /// - moveWindowToMainScreen（AX 路径）的最终 AX 落盘步骤（唯一调用方，maxAttempts=3；
    ///   restore 已改走 moveWindowToFrameViaYabai 直写，不再进本函数）；
    /// - 跨屏移动不走本函数：裸 AX position 写会被 WindowServer clamp 在源屏，跨屏一律
    ///   moveWindowToFrameViaYabai 直写。size 先 position 后的顺序保留：size readback
    ///   在 position 写之前不被跨屏阻塞（task #7 回退教训）。
    /// AX 尺寸直写（同屏 resize，2026-09-04 混合写入优化）。
    ///
    /// ## 场景
    /// moveWindowToFrameViaYabai 的 resize 段：窗口未跨屏（源屏收窄 / 已达目标屏放大）
    /// 时 AX 同屏写有效且无进程 fork（~25ms vs yabai fork 40-90ms）。窗口已 float
    /// （restore/move_to_main 前置）不受 yabai re-tile 影响，AX 写不会被覆盖。
    /// 跨屏 resize（窗口在 A 屏写 B 屏尺寸）仍须 yabai（裸 AX 被 WindowServer clamp，
    /// T3 断言），调用方负责按 writeOrder 保证同屏前提，AX 不可写时由调用方 fallback yabai。
    func resizeViaAX(
        targetFrame: CGRect,
        window: AXUIElement,
        windowID: UInt32,
        op: String,
        stage: String
    ) -> Bool {
        let outcome = writeSizeWithReadback(
            targetFrame: targetFrame,
            window: window,
            attempts: 2,
            settleDelayMicros: WindowSettle.axWriteSettleMicros,
            op: op,
            stage: stage,
            windowID: windowID
        )
        return outcome.axOK && outcome.matched
    }

    func apply(
        frame targetFrame: CGRect,
        to window: AXUIElement,
        operationID: String? = nil,
        stage: String = "apply_frame",
        maxAttempts: Int = 3,
        windowID: UInt32? = nil
    ) -> Bool {
        let op = operationID ?? "none"
        let startedAt = Date()
        let attempts = max(1, maxAttempts)
        let settleDelayMicros: useconds_t = WindowSettle.axWriteSettleMicros

        var sizeAttemptsUsed = 0
        var sizeReadbackMatched = false
        // P-INST-7: 累积 size write + readback 耗时，区分 phase2Ms/applyMs 中 write/settle(usleep)/readback 的占比。
        var sizeWriteSetMs = 0
        var sizeReadbackMs = 0
        // P-INST-23: 累积 position write 耗时（AX write 异步应 <5ms）。
        var positionWriteMs = 0

        // Phase 1: size write + readback。
        // size write 不触发跨屏移动，readback 在 position write 之前不被 WindowServer 跨屏阻塞。
        let phase1Start = Date()
        let sizeOutcome = writeSizeWithReadback(
            targetFrame: targetFrame,
            window: window,
            attempts: attempts,
            settleDelayMicros: settleDelayMicros,
            op: op,
            stage: stage,
            windowID: windowID
        )
        guard sizeOutcome.axOK else {
            return false
        }
        sizeAttemptsUsed = sizeOutcome.attemptsUsed
        sizeReadbackMatched = sizeOutcome.matched
        sizeWriteSetMs = sizeOutcome.writeSetMs
        sizeReadbackMs = sizeOutcome.readbackMs
        let phase1Ms = elapsedMilliseconds(since: phase1Start)

        // Phase 2 position write — 单次。跨屏移动的 WindowServer 阻塞只发生这一次
        // （旧实现因 position 在循环内阻塞 maxAttempts 次）。size 已在 Phase 1 验证生效
        // （maxAttempts>1）或单次写入（maxAttempts=1），position 单次 write 即可。
        let phase2Start = Date()
        guard writePosition(targetFrame: targetFrame, window: window, op: op, stage: stage, writeMs: &positionWriteMs) else {
            return false
        }
        let phase2Ms = elapsedMilliseconds(since: phase2Start)

        log("[apply] done", level: .debug, fields: [
            "op": op, "stage": stage, "attempts": String(attempts),
            "durationMs": String(elapsedMilliseconds(since: startedAt)),
            "phase1Ms": String(phase1Ms),
            "phase2Ms": String(phase2Ms),
            "sizeAttempts": String(sizeAttemptsUsed),
            "sizeReadbackMatched": String(sizeReadbackMatched),
            // P-INST-7: write/readback 细分。settleMs = phase1Ms+phase2Ms - writeSetMs - readbackMs - positionWriteMs（usleep 25ms×attempts 主导则 settleMs 大）。
            "sizeWriteSetMs": String(sizeWriteSetMs),
            "sizeReadbackMs": String(sizeReadbackMs),
            // P-INST-23: position write 耗时（AX write 异步应 <5ms；phase2Ms 中非 settle 的实际 AX write 成本）。
            "positionWriteMs": String(positionWriteMs)
        ])
        return true
    }

    /// size write + readback（收敛循环统一走 FrameConvergence.convergeFrame，2.16a 第十四刀）。
    /// axOK=false 表示 AX 调用失败（调用方应中止 apply）；matched=false 表示 size 未在
    /// readback 中确认生效（可能被 WindowServer clamp，move_to_main 反转 Phase 后应罕见）。
    /// 历史"restore 单次模式不 readback"已随 restore 改走 moveWindowToFrameViaYabai 直写
    /// 而失去消费者（apply 唯一调用方传 maxAttempts=3），分支删除。
    private func writeSizeWithReadback(
        targetFrame: CGRect,
        window: AXUIElement,
        attempts: Int,
        settleDelayMicros: useconds_t,
        op: String,
        stage: String,
        windowID: UInt32? = nil
    ) -> (axOK: Bool, attemptsUsed: Int, matched: Bool, writeSetMs: Int, readbackMs: Int) {
        var attemptsUsed = 0
        var writeSetMs = 0
        var readbackMs = 0
        let outcome = FrameConvergence.convergeFrame(
            attempts: attempts,
            settleMicros: settleDelayMicros,
            write: {
                attemptsUsed += 1
                let write = axWriteSizeOnce(targetFrame: targetFrame, window: window, op: op, stage: stage, attempt: attemptsUsed)
                writeSetMs += write.writeMs
                return write.axOK
            },
            read: {
                // size readback：优先 CGWindowList（非阻塞 ~2ms），替代 AX frame(of:)（WindowServer 同步
                // 等待 ~68ms 波动，phase2Ms 98ms 主因）。windowID 由调用方传入（move_to_main 给
                // effectiveWindowID）；windowID=nil（restore 单次模式不 readback，或未传）回退 AX 兼容。
                // memory feedback_toggle_ctxms_cgwindowlist：热路径读 frame 禁 AX，必须 CGWindowList。
                // P-INST-7: readback 计时（cgWindowBounds ~2ms / AX frame(of:) ~68ms，区分 readback 路径成本）。
                let readbackStart = Date()
                let appliedFrame: CGRect?
                if let wid = windowID {
                    appliedFrame = cgWindowBounds(for: wid)
                } else {
                    appliedFrame = frame(of: window)
                }
                readbackMs += elapsedMilliseconds(since: readbackStart)
                return appliedFrame
            },
            isConverged: { CoordinateKit.isSizeConverged(actual: $0.size, target: targetFrame.size, tolerance: frameTolerance) }
        )
        switch outcome {
        case .converged:
            return (true, attemptsUsed, true, writeSetMs, readbackMs)
        case .mismatched:
            return (true, attemptsUsed, false, writeSetMs, readbackMs)
        case .writeFailed:
            return (false, attemptsUsed, false, writeSetMs, readbackMs)
        }
    }

    /// 单次 AX size 写（AXValueCreate + SetAttributeValue）。axOK=false 即 AXValueCreate 失败
    /// 或 AX 返回错误码，writeSizeWithReadback 视为硬失败中止。
    private func axWriteSizeOnce(
        targetFrame: CGRect,
        window: AXUIElement,
        op: String,
        stage: String,
        attempt: Int
    ) -> (axOK: Bool, writeMs: Int) {
        var targetSize = CGSize(width: targetFrame.width, height: targetFrame.height)
        guard let sizeValue = AXValueCreate(.cgSize, &targetSize) else {
            log(
                "[apply] AXValueCreate for size returned nil",
                level: .error,
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt),
                    "targetWidth": "\(targetFrame.width)",
                    "targetHeight": "\(targetFrame.height)"
                ]
            )
            return (false, 0)
        }

        // P-INST-7: size write 计时（AXUIElementSetAttributeValue，AX write 异步应 <5ms；若高说明跨屏阻塞）。
        let writeStart = Date()
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let writeMs = elapsedMilliseconds(since: writeStart)
        guard sizeResult == .success else {
            log(
                "[apply] AXUIElementSetAttributeValue for size failed",
                level: .error,
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt),
                    "sizeResult": String(sizeResult.rawValue)
                ]
            )
            return (false, writeMs)
        }
        return (true, writeMs)
    }

    /// position write — 单次 AXUIElementSetAttributeValue(kAXPositionAttribute)。
    /// AX write 异步返回（不等待 WindowServer 实际移动），不跨屏阻塞。
    @discardableResult
    private func writePosition(
        targetFrame: CGRect,
        window: AXUIElement,
        op: String,
        stage: String,
        writeMs: inout Int
    ) -> Bool {
        var targetOrigin = CGPoint(x: targetFrame.origin.x, y: targetFrame.origin.y)
        guard let originValue = AXValueCreate(.cgPoint, &targetOrigin) else {
            log(
                "[apply] AXValueCreate for position returned nil",
                level: .error,
                fields: [
                    "op": op,
                    "stage": stage,
                    "targetX": "\(targetFrame.origin.x)",
                    "targetY": "\(targetFrame.origin.y)"
                ]
            )
            return false
        }

        let posWriteStart = Date()
        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
        writeMs &+= elapsedMilliseconds(since: posWriteStart)
        guard positionResult == .success else {
            log(
                "[apply] AXUIElementSetAttributeValue for position failed",
                level: .error,
                fields: [
                    "op": op,
                    "stage": stage,
                    "positionResult": String(positionResult.rawValue)
                ]
            )
            return false
        }
        return true
    }
}
