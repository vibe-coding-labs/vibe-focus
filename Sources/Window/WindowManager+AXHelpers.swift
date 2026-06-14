import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - AX Helpers
@MainActor
extension WindowManager {

    func windowHandle(for window: AXUIElement) -> UInt32? {
        var windowID: CGWindowID = 0
        let status = _AXUIElementGetWindow(window, &windowID)
        guard status == .success, windowID != 0 else {
            return nil
        }
        return windowID
    }

    func windowNumber(for window: AXUIElement) -> Int? {
        var numberRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, axWindowNumberAttribute as CFString, &numberRef)
        guard status == .success, let number = numberRef as? NSNumber else {
            return nil
        }
        return number.intValue
    }

    func title(of window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        guard status == .success else {
            return nil
        }
        return titleRef as? String
    }

    func frame(of window: AXUIElement) -> CGRect? {
        var frameRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, axFrameAttribute as CFString, &frameRef)
        guard status == .success, let frameRef else {
            return nil
        }

        let axValue = unsafeBitCast(frameRef, to: AXValue.self)
        var frame = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &frame) else {
            return nil
        }
        return frame
    }

    func isAttributeSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        if status != .success {
            log("Settable check failed for \(attribute): \(status.rawValue)")
            return false
        }
        return settable.boolValue
    }

    func apply(
        frame targetFrame: CGRect,
        to window: AXUIElement,
        operationID: String? = nil,
        stage: String = "apply_frame",
        maxAttempts: Int = 3
    ) -> Bool {
        let op = operationID ?? "none"
        let startedAt = Date()
        let attempts = max(1, maxAttempts)
        let settleDelayMicros: useconds_t = 25_000

        // Phase 1/Phase 2 耗时分解埋点：定位 size readback 循环开销 vs 跨屏 position 阻塞（历史 spike 主因）。
        let phase1Start = Date()
        var sizeAttemptsUsed = 0
        var sizeReadbackMatched = false

        // Phase 1: size write + readback retry。
        // 关键优化：size write 不触发跨屏移动，readback 在 Phase 2 的 position write 之前进行，
        // 不被 WindowServer 跨屏阻塞。旧实现 size+position 在同一循环，position 跨屏阻塞拖累
        // 每次循环的 size readback，3 次累积 1300ms+（move_to_main spike 主因）。分离后 size 验证
        // 仍用 maxAttempts 次确保 height 可靠生效（maxAttempts≠1 的核心目的），position 跨屏阻塞只发生一次。
        for attempt in 1...attempts {
            sizeAttemptsUsed = attempt
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

            let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
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

            // 单次模式（restore）：跳过 size readback，直接进 Phase 2 position write。
            if attempts == 1 { break }

            usleep(settleDelayMicros)

            // size readback：窗口此时未跨屏移动（position write 在 Phase 2），readback 不被阻塞。
            if let appliedFrame = frame(of: window),
               abs(appliedFrame.width - targetFrame.width) <= frameTolerance,
               abs(appliedFrame.height - targetFrame.height) <= frameTolerance {
                sizeReadbackMatched = true
                break  // size 已生效
            }
            // size 未生效，retry（attempt < attempts）
        }
        let phase1Ms = elapsedMilliseconds(since: phase1Start)

        // Phase 2: position write — 单次。
        // 跨屏移动的 WindowServer 阻塞只发生这一次（旧实现因 position 在循环内阻塞 maxAttempts 次）。
        // size 已在 Phase 1 验证生效（maxAttempts>1）或单次写入（maxAttempts=1），position 单次 write 即可。
        let phase2Start = Date()
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

        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
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
        let phase2Ms = elapsedMilliseconds(since: phase2Start)

        log("[apply] done", level: .debug, fields: [
            "op": op, "stage": stage, "attempts": String(attempts),
            "durationMs": String(elapsedMilliseconds(since: startedAt)),
            "phase1Ms": String(phase1Ms),
            "phase2Ms": String(phase2Ms),
            "sizeAttempts": String(sizeAttemptsUsed),
            "sizeReadbackMatched": String(sizeReadbackMatched)
        ])
        return true
    }
}
