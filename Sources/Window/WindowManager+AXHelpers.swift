import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - AX Helpers
// AXUIElement 工具方法：windowHandle、title、frame、apply
@MainActor
extension WindowManager {

    func windowHandle(for window: AXUIElement) -> UInt32? {
        var windowID: CGWindowID = 0
        let status = _AXUIElementGetWindow(window, &windowID)
        guard status == .success, windowID != 0 else {
            log(
                "[WindowManager] windowHandle: _AXUIElementGetWindow failed",
                level: .debug,
                fields: ["axStatus": String(status.rawValue)]
            )
            return nil
        }
        return windowID
    }

    /// 验证 AXUIElement 是否仍然有效（底层窗口未被销毁）
    func isValidAXElement(_ element: AXUIElement) -> Bool {
        var windowID: CGWindowID = 0
        let status = _AXUIElementGetWindow(element, &windowID)
        guard status == .success, windowID != 0 else {
            log(
                "[WindowManager] isValidAXElement: _AXUIElementGetWindow failed",
                level: .debug,
                fields: ["axStatus": String(status.rawValue)]
            )
            return false
        }
        let valid = validateWindowExists(windowID: windowID)
        log(
            "[WindowManager] isValidAXElement result",
            level: .debug,
            fields: ["windowID": String(windowID), "valid": String(valid)]
        )
        return valid
    }

    struct CGWindowSnapshot {
        let windowID: UInt32
        let title: String?
        let frame: CGRect
        let ownerPID: pid_t
        let layer: Int
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
            log(
                "[WindowManager] frame: AX read failed",
                level: .debug,
                fields: ["axStatus": String(status.rawValue)]
            )
            return nil
        }

        let axValue = unsafeBitCast(frameRef, to: AXValue.self)
        var frame = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &frame) else {
            log(
                "[WindowManager] frame: AXValueGetValue failed",
                level: .debug
            )
            return nil
        }
        return frame
    }

    /// 读取窗口 frame，优先使用 yabai 交叉校验确保准确性。
    /// AX API 对非可见 Space 上的窗口返回错误坐标，yabai 始终准确。
    /// 调用方应优先使用此方法而非 frame(of:)，除非确定窗口可见。
    func readAccurateFrame(windowID: UInt32, axElement: AXUIElement) -> CGRect? {
        guard let axFrame = frame(of: axElement) else {
            return nil
        }
        // 主屏窗口 AX frame 准确，不需要 yabai 校验
        // yabai 使用 Cocoa 坐标（Y-up），AX 使用 Quartz 坐标（Y-down）
        // 对主屏窗口做 yabai override 会因坐标系不同导致错误
        if isWindowOnMainScreen(windowID: windowID) {
            return axFrame
        }
        guard let yabaiInfo = spaceController.queryWindow(windowID: windowID),
              let yabaiFrame = yabaiInfo.frame else {
            return axFrame
        }
        // yabai 返回 Quartz 坐标（Y-down, origin at top-left of primary）
        // 与 AX/apply 坐标系一致，不需要转换
        let yabaiRect = yabaiFrame.cgRect
        let positionDiff = hypot(yabaiRect.midX - axFrame.midX, yabaiRect.midY - axFrame.midY)
        if positionDiff > frameTolerance * 3 {
            log(
                "[WindowManager] readAccurateFrame: yabai override (Quartz, no conversion needed)",
                level: .info,
                fields: [
                    "windowID": String(windowID),
                    "axFrame": "\(axFrame)",
                    "yabaiQuartz": "\(yabaiRect)",
                    "positionDiff": String(format: "%.0f", positionDiff)
                ]
            )
            return yabaiRect
        }
        return axFrame
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

        log(
            "[apply] starting frame application",
            level: .debug,
            fields: [
                "op": op,
                "stage": stage,
                "targetFrame": String(describing: targetFrame),
                "maxAttempts": String(maxAttempts)
            ]
        )

        for attempt in 1...maxAttempts {
            log(
                "[apply] attempt started",
                level: .debug,
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt)
                ]
            )
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
            log(
                "[WindowManager] set size result",
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt),
                    "status": String(sizeResult.rawValue)
                ]
            )
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

            log(
                "[apply] size set OK, setting position",
                level: .debug,
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt)
                ]
            )

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
            log(
                "[WindowManager] set position result",
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt),
                    "status": String(positionResult.rawValue)
                ]
            )
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

            log(
                "[apply] position set OK, waiting settle delay",
                level: .debug,
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt),
                    "settleDelayMs": String(settleDelayMicros / 1000)
                ]
            )

            usleep(settleDelayMicros)

            log(
                "[apply] reading back frame after settle",
                level: .debug,
                fields: ["op": op, "stage": stage, "attempt": String(attempt)]
            )
            // AX-safe: verifying frame after apply — window was just manipulated
            if let appliedFrame = frame(of: window) {
                log(
                    "[WindowManager] applied frame snapshot",
                    fields: [
                        "op": op,
                        "stage": stage,
                        "attempt": String(attempt),
                        "frame": String(describing: appliedFrame)
                    ]
                )
                lastAppliedFrame = appliedFrame
                if framesMatch(appliedFrame, targetFrame) {
                    log(
                        "[apply] frame matched on attempt, returning true",
                        level: .debug,
                        fields: [
                            "op": op,
                            "stage": stage,
                            "attempt": String(attempt)
                        ]
                    )
                    return true
                }
                log(
                    "[apply] frame did not match on attempt, checking tolerance",
                    level: .debug,
                    fields: [
                        "op": op,
                        "stage": stage,
                        "attempt": String(attempt),
                        "appliedFrame": String(describing: appliedFrame),
                        "targetFrame": String(describing: targetFrame)
                    ]
                )
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

        log(
            "[apply] all attempts exhausted, checking tolerance as final fallback",
            level: .debug,
            fields: [
                "op": op,
                "stage": stage,
                "hasLastAppliedFrame": String(lastAppliedFrame != nil)
            ]
        )

        // 如果精确匹配失败，但窗口已成功应用了接近的尺寸（可能是窗口有最小尺寸限制）
        // 我们也认为是成功的
        if let lastFrame = lastAppliedFrame {
            // 检查是否在合理范围内（位置正确，大小接近）
            let positionMatches = abs(lastFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
                                 abs(lastFrame.origin.y - targetFrame.origin.y) <= frameTolerance
            let sizeCloseEnough = abs(lastFrame.width - targetFrame.width) <= frameTolerance * 2 &&
                                 abs(lastFrame.height - targetFrame.height) <= 100 // 允许高度有较大偏差（最小尺寸限制）

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
