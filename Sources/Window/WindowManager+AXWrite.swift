import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - AX 写入编排层（2026-08-31 从 +AXHelpers.swift 拆分，行为不变）
// apply 两阶段（size + position）frame 写入及其子步骤。读取原语见 +AXRead.swift。

@MainActor
extension WindowManager {

    /// 写入目标 frame。两阶段（size + position）顺序由 positionFirst 决定：
    /// - `positionFirst=false`（默认，restore）：Phase 1 size write + readback retry，Phase 2 position write。
    /// - `positionFirst=true`（move_to_main）：Phase 1 position write，Phase 2 size write + readback retry。
    /// phase1Ms/phase2Ms 始终是"第一个操作/第二个操作"的耗时，具体语义随 positionFirst 变化（见日志 positionFirst 字段）。
    ///
    /// ## 场景
    /// - moveWindowToMainScreen / restore 的最终 AX 落盘步骤；
    /// - 顺序选择是两个历史 bug 的修复载体（详见 positionFirst 分支注释）：
    ///   move_to_main 的 P2 yabai 路径必须 position 先（size 先会被副屏 visibleFrame
    ///   clamp 出半屏高）；restore 保持 size 先（position 先的 size readback 跨屏阻塞，
    ///   task #7 回退教训）。
    func apply(
        frame targetFrame: CGRect,
        to window: AXUIElement,
        operationID: String? = nil,
        stage: String = "apply_frame",
        maxAttempts: Int = 3,
        positionFirst: Bool = false,
        windowID: UInt32? = nil
    ) -> Bool {
        let op = operationID ?? "none"
        let startedAt = Date()
        let attempts = max(1, maxAttempts)
        let settleDelayMicros: useconds_t = 25_000

        var sizeAttemptsUsed = 0
        var sizeReadbackMatched = false
        // P-INST-7: 累积 size write + readback 耗时，区分 phase2Ms/applyMs 中 write/settle(usleep)/readback 的占比。
        var sizeWriteSetMs = 0
        var sizeReadbackMs = 0
        // P-INST-23: 累积 position write 耗时（AX write 异步应 <5ms；positionFirst=true 时是 phase1 主操作，验证不阻塞）。
        var positionWriteMs = 0

        let phase1Start = Date()
        if positionFirst {
            // move_to_main P2 路径：position 先把窗口物理移到主屏，settle 等移动，再 size write 主屏全屏。
            // 根因（半屏 bug）：P2 yabai space move 移 space 不移物理 frame，size write 时窗口物理仍在副屏，
            // WindowServer 把 height clamp 到副屏 visibleFrame 高（707），sizeDrift=372 需 postMoveCheck rewrite
            // （P2 压测 5/9 命中）。position write（主屏坐标）异步移物理副屏→主屏；settle 等 WindowServer 移动完成，
            // size write 时窗口物理主屏，受主屏 visibleFrame（高 1079）限制不 clamp，一次生效，postMoveCheck
            // drift 归零，省 rewrite ~75ms + apply readback 重试 ~50ms。position write 本身不跨屏阻塞（AX write 异步）。
            // 仅 P2 yabai 路径用（窗口已 yabai space move 到主屏 space，物理副屏）；AX 路径（窗口副屏）position 先
            // 的 size readback 跨屏阻塞（task #7 回退），保持 size 先（positionFirst=false）。
            guard writePosition(targetFrame: targetFrame, window: window, op: op, stage: stage, writeMs: &positionWriteMs) else {
                return false
            }
            usleep(settleDelayMicros)
        } else {
            // size 先（restore）：Phase 1 size write + readback，Phase 2 position write。
            // size write 不触发跨屏移动，readback 在 position write 之前不被 WindowServer 跨屏阻塞。
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
        }
        let phase1Ms = elapsedMilliseconds(since: phase1Start)

        let phase2Start = Date()
        if positionFirst {
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
        } else {
            // Phase 2 position write — 单次。跨屏移动的 WindowServer 阻塞只发生这一次
            // （旧实现因 position 在循环内阻塞 maxAttempts 次）。size 已在 Phase 1 验证生效
            // （maxAttempts>1）或单次写入（maxAttempts=1），position 单次 write 即可。
            guard writePosition(targetFrame: targetFrame, window: window, op: op, stage: stage, writeMs: &positionWriteMs) else {
                return false
            }
        }
        let phase2Ms = elapsedMilliseconds(since: phase2Start)

        log("[apply] done", level: .debug, fields: [
            "op": op, "stage": stage, "attempts": String(attempts),
            "positionFirst": String(positionFirst),
            "durationMs": String(elapsedMilliseconds(since: startedAt)),
            "phase1Ms": String(phase1Ms),
            "phase2Ms": String(phase2Ms),
            "sizeAttempts": String(sizeAttemptsUsed),
            "sizeReadbackMatched": String(sizeReadbackMatched),
            // P-INST-7: write/readback 细分。settleMs = phase1Ms+phase2Ms - writeSetMs - readbackMs - positionWriteMs（usleep 25ms×attempts 主导则 settleMs 大）。
            "sizeWriteSetMs": String(sizeWriteSetMs),
            "sizeReadbackMs": String(sizeReadbackMs),
            // P-INST-23: position write 耗时（AX write 异步应 <5ms；phase1Ms/phase2Ms 中非 settle/readback 的实际 AX write 成本）。
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

    /// 写入后闭环验证：读 CGWindow 实际 frame 与目标比对，不符则重写 position+size。
    ///
    /// ## 场景（2026-09-01 新增，toggle 尺寸/位置错乱修复）
    /// - yabai v7 float 布局下 float toggle 会触发 yabai 默认重摆，与 apply 的 AX 写异步竞争，
    ///   单次写可能被覆盖（实测 post-move 出现 762,-555 1000x620 之类的中间态）。
    /// - 本方法在 apply 之后调用：读实际 frame → 与目标比对（origin+size 双维度）→
    ///   不符则重写并等待 WindowServer 落定 → 再验证。重写次数用尽仍不符时落 ERROR 日志。
    /// - 返回累计耗时（ms）供上层诊断字段使用。
    func ensureWindowAtFrame(
        windowAX: AXUIElement,
        windowID: UInt32,
        targetFrame: CGRect,
        op: String,
        stage: String,
        maxRewrites: Int = 2
    ) -> Int {
        let start = Date()
        for attempt in 1...maxRewrites {
            guard let current = cgWindowBounds(for: windowID) else { break }
            let originDrift = abs(current.origin.x - targetFrame.origin.x) + abs(current.origin.y - targetFrame.origin.y)
            let sizeDrift = abs(current.width - targetFrame.width) + abs(current.height - targetFrame.height)
            guard originDrift > frameTolerance || sizeDrift > frameTolerance else {
                log("[WindowManager] ensureWindowAtFrame: verified", level: .debug, fields: [
                    "op": op, "stage": stage, "windowID": String(windowID),
                    "attempt": String(attempt),
                    "frame": "\(Int(current.origin.x)),\(Int(current.origin.y)) \(Int(current.width))x\(Int(current.height))"
                ])
                break
            }
            log("[WindowManager] ensureWindowAtFrame: rewriting frame", level: .warn, fields: [
                "op": op, "stage": stage, "windowID": String(windowID),
                "attempt": String(attempt),
                "current": "\(Int(current.origin.x)),\(Int(current.origin.y)) \(Int(current.width))x\(Int(current.height))",
                "target": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.width))x\(Int(targetFrame.height))",
                "originDrift": String(Int(originDrift)),
                "sizeDrift": String(Int(sizeDrift))
            ])
            var rewriteOrigin = CGPoint(x: targetFrame.origin.x, y: targetFrame.origin.y)
            if let originValue = AXValueCreate(.cgPoint, &rewriteOrigin) {
                _ = AXUIElementSetAttributeValue(windowAX, kAXPositionAttribute as CFString, originValue)
            }
            var rewriteSize = CGSize(width: targetFrame.width, height: targetFrame.height)
            if let sizeValue = AXValueCreate(.cgSize, &rewriteSize) {
                _ = AXUIElementSetAttributeValue(windowAX, kAXSizeAttribute as CFString, sizeValue)
            }
            // 250ms：AX 写异步生效 + yabai/WindowServer 重摆落定（实测中间态在 ~150ms 内收敛）
            usleep(250_000)
        }
        return elapsedMilliseconds(since: start)
    }
}
