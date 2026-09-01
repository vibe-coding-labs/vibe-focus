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
    /// - moveWindowToMainScreen（AX 路径）/ restore 的最终 AX 落盘步骤；
    /// - 跨屏移动不走本函数：P2 路径用 moveWindowToFrameViaYabai 直写（裸 AX position 写
    ///   会被 WindowServer clamp 在源屏）。旧 positionFirst=true 分支（P2 yabai space move
    ///   时代的"position 先防 clamp"）随该路径废弃一并删除，size 先的顺序保留是 restore
    ///   的 readback 不被跨屏阻塞（task #7 回退教训）。
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
        guard writeSizeWithReadback(
            targetFrame: targetFrame,
            window: window,
            attempts: attempts,
            settleDelayMicros: settleDelayMicros,
            op: op,
            stage: stage,
            attemptsUsed: &sizeAttemptsUsed,
            matched: &sizeReadbackMatched,
            writeSetMs: &sizeWriteSetMs,
            readbackMs: &sizeReadbackMs,
            windowID: windowID
        ) else {
            return false
        }
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

    /// size write + readback retry。返回 false 表示 AX 调用失败（调用方应中止 apply）；
    /// `attemptsUsed`/`matched` 通过 inout 回传。`matched=false` 表示 size 未在 readback 中确认生效
    /// （可能被 WindowServer clamp，move_to_main 反转 Phase 后应罕见；restore 单次模式不 readback）。
    @discardableResult
    private func writeSizeWithReadback(
        targetFrame: CGRect,
        window: AXUIElement,
        attempts: Int,
        settleDelayMicros: useconds_t,
        op: String,
        stage: String,
        attemptsUsed: inout Int,
        matched: inout Bool,
        writeSetMs: inout Int,
        readbackMs: inout Int,
        windowID: UInt32? = nil
    ) -> Bool {
        for attempt in 1...attempts {
            attemptsUsed = attempt
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
                return false
            }

            // P-INST-7: size write 计时（AXUIElementSetAttributeValue，AX write 异步应 <5ms；若高说明跨屏阻塞）。
            let writeStart = Date()
            let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            writeSetMs &+= elapsedMilliseconds(since: writeStart)
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
                return false
            }

            // 单次模式（restore）：跳过 size readback，直接进 position write。
            if attempts == 1 { break }

            usleep(settleDelayMicros)

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
            readbackMs &+= elapsedMilliseconds(since: readbackStart)
            if let appliedFrame,
               abs(appliedFrame.width - targetFrame.width) <= frameTolerance,
               abs(appliedFrame.height - targetFrame.height) <= frameTolerance {
                matched = true
                break  // size 已生效
            }
            // size 未生效，retry（attempt < attempts）
        }
        return true
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
