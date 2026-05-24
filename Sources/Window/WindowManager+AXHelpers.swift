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
        stage: String = "apply_frame"
    ) -> Bool {
        let op = operationID ?? "none"
        let startedAt = Date()
        var lastAppliedFrame: CGRect?
        let maxAttempts = 3
        let settleDelayMicros: useconds_t = 25_000

        for attempt in 1...maxAttempts {
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

            var targetOrigin = CGPoint(x: targetFrame.origin.x, y: targetFrame.origin.y)
            guard let originValue = AXValueCreate(.cgPoint, &targetOrigin) else {
                log(
                    "[apply] AXValueCreate for position returned nil",
                    level: .error,
                    fields: [
                        "op": op,
                        "stage": stage,
                        "attempt": String(attempt),
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
                        "attempt": String(attempt),
                        "positionResult": String(positionResult.rawValue)
                    ]
                )
                return false
            }

            usleep(settleDelayMicros)

            // AX-safe: verifying frame after apply — window was just manipulated
            if let appliedFrame = frame(of: window) {
                lastAppliedFrame = appliedFrame
                if framesMatch(appliedFrame, targetFrame) {
                    return true
                }
            } else {
                log(
                    "[apply] could not read back frame on attempt",
                    level: .warn,
                    fields: [
                        "op": op,
                        "stage": stage,
                        "attempt": String(attempt)
                    ]
                )
            }
        }

        // 如果精确匹配失败，但窗口已成功应用了接近的尺寸（可能是窗口有最小尺寸限制）
        if let lastFrame = lastAppliedFrame {
            let positionMatches = abs(lastFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
                                 abs(lastFrame.origin.y - targetFrame.origin.y) <= frameTolerance
            let sizeCloseEnough = abs(lastFrame.width - targetFrame.width) <= frameTolerance * 2 &&
                                 abs(lastFrame.height - targetFrame.height) <= frameTolerance * 2

            if positionMatches && sizeCloseEnough {
                log(
                    "[WindowManager] apply frame within tolerance",
                    level: .warn,
                    fields: [
                        "op": op,
                        "stage": stage,
                        "frame": String(describing: lastFrame),
                        "target": String(describing: targetFrame),
                        "durationMs": String(elapsedMilliseconds(since: startedAt))
                    ]
                )
                return true
            }
        }

        log(
            "[WindowManager] apply frame failed",
            level: .error,
            fields: [
                "op": op,
                "stage": stage,
                "target": String(describing: targetFrame),
                "lastFrame": String(describing: lastAppliedFrame),
                "durationMs": String(elapsedMilliseconds(since: startedAt))
            ]
        )
        return false
    }
}
