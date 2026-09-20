import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - AX 读取原语层（2026-08-31 从 +AXHelpers.swift 拆分，行为不变）
// 只读的 AX 属性查询：windowHandle / windowNumber / title / frame / isAttributeSettable。
// 写入编排（apply 两阶段 size+position）见 +AXWrite.swift。
//
// ## 铁律（memory feedback_toggle_ctxms_cgwindowlist）
// 副屏独立 Space 的窗口，AX 属性查询会被 WindowServer 阻塞 1-2s。toggle/move 热路径
// 读 frame/windowID 必须用 CGWindowList（cgWindowBounds/cgWindowListAll，非阻塞快照），
// 本层仅用于非热路径诊断与已确认不阻塞的场景（如窗口已被 yabai space move 到主屏后）。

extension WindowManager {

    /// Extract the CGWindowID from an AXUIElement window reference.
    ///
    /// Uses `_AXUIElementGetWindow` (private but stable API). This is the primary
    /// way to bridge from AX elements to CGWindowIDs for CGWindowList queries.
    ///
    /// - Parameter window: AXUIElement representing a window
    /// - Returns: CGWindowID if extraction succeeds, nil otherwise
    func windowHandle(for window: AXUIElement) -> UInt32? {
        // P-INST-44: _AXUIElementGetWindow AX 耗时（slow-op ≥50ms warn；AX 正常 <10ms，阻塞 >>50ms）。
        #if PERF_INSTRUMENT
        let whAxStart = Date()
        #endif
        var windowID: CGWindowID = 0
        let status = _AXUIElementGetWindow(window, &windowID)
        let found = status == .success && windowID != 0
        #if PERF_INSTRUMENT
        let whDurMs = elapsedMilliseconds(since: whAxStart)
        if whDurMs >= 50 {
            log("[WindowManager] windowHandle slow AX", level: .warn, fields: ["durationMs": String(whDurMs), "found": String(found)])
        }
        #endif
        guard found else {
            return nil
        }
        return windowID
    }

    /// 读取 AX windowNumber（CGWindowNumber，跨 space move 稳定）。
    func windowNumber(for window: AXUIElement) -> Int? {
        // P-INST-44: AX windowNumber 读取耗时（slow-op ≥50ms warn）。
        #if PERF_INSTRUMENT
        let wnAxStart = Date()
        #endif
        var numberRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, axWindowNumberAttribute as CFString, &numberRef)
        #if PERF_INSTRUMENT
        let wnDurMs = elapsedMilliseconds(since: wnAxStart)
        if wnDurMs >= 50 {
            log("[WindowManager] windowNumber slow AX", level: .warn, fields: ["durationMs": String(wnDurMs)])
        }
        #endif
        guard status == .success, let number = numberRef as? NSNumber else {
            return nil
        }
        return number.intValue
    }

    /// 读取 AX 窗口标题。
    func title(of window: AXUIElement) -> String? {
        // P-INST-44: AX title 读取耗时（slow-op ≥50ms warn）。
        #if PERF_INSTRUMENT
        let titleAxStart = Date()
        #endif
        var titleRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        #if PERF_INSTRUMENT
        let titleDurMs = elapsedMilliseconds(since: titleAxStart)
        if titleDurMs >= 50 {
            log("[WindowManager] title(of:) slow AX", level: .warn, fields: ["durationMs": String(titleDurMs)])
        }
        #endif
        guard status == .success else {
            return nil
        }
        return titleRef as? String
    }

    /// Read the frame of an AX window element.
    ///
    /// **WARNING:** This function can block 1-2 seconds when the window is on a
    /// secondary screen with independent Spaces. Toggle hot-path MUST use
    /// `cgWindowFrame(forWindowID:)` instead. This function is kept for
    /// non-hot-path diagnostics and post-move verification only.
    /// See `feedback_toggle_ctxms_cgwindowlist` for the mandate.
    ///
    /// - Parameter window: AXUIElement representing a window
    /// - Returns: The window's frame in global coordinates, or nil on failure
    func frame(of window: AXUIElement) -> CGRect? {
        // P-INST-44: AX frame 读取耗时（已知阻塞元凶，副屏独立 Space 可阻塞 1-2s；memory feedback_toggle_ctxms_cgwindowlist 铁律 toggle 热路径禁用此函数，always debug 用于监控违规调用 + 阻塞归因）。
        #if PERF_INSTRUMENT
        let frameAxStart = Date()
        defer {
            log("[WindowManager] AX frame(of:) finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: frameAxStart))
            ])
        }
        #endif
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

    /// Check whether an AX attribute is settable on an element.
    ///
    /// Called before every window move operation to verify the attribute can be written.
    /// Can block if the AX connection is slow.
    ///
    /// - Parameters:
    ///   - element: AXUIElement to check
    ///   - attribute: Attribute name (e.g., kAXFrameAttribute, kAXPositionAttribute)
    /// - Returns: true if the attribute is settable
    func isAttributeSettable(_ element: AXUIElement, attribute: String) -> Bool {
        // P-INST-44: AX isAttributeSettable 耗时（slow-op ≥50ms warn；每次 window move 前调用）。
        #if PERF_INSTRUMENT
        let settableAxStart = Date()
        #endif
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        #if PERF_INSTRUMENT
        let settableDurMs = elapsedMilliseconds(since: settableAxStart)
        if settableDurMs >= 50 {
            log("[WindowManager] isAttributeSettable slow AX", level: .warn, fields: ["attribute": attribute, "durationMs": String(settableDurMs)])
        }
        #endif
        if status != .success {
            log("Settable check failed for \(attribute): \(status.rawValue)")
            return false
        }
        return settable.boolValue
    }

    /// B308：读终端窗口的屏幕文本（首个 AXTextArea 的 AXValue，深度优先）。
    /// 提交链粘贴落地验证专用：目标窗此刻是前台 key window（可见 space，
    /// 不在铁律的副屏独立 Space 阻塞禁区）；读不到/无文本区返回 nil，验证
    /// 路径自动降级超时兜底，绝不阻塞提交。
    /// nonisolated 纯 C 调用：可在后台队列执行（深树遍历不上主线程，B305 教训）。
    nonisolated static func terminalScreenText(of window: AXUIElement) -> String? {
        // 单次 AX 调用耗时封顶：读不到快速失败走降级，不拖死验证循环
        //（虽在后台队列，预算仍要可控）。
        AXUIElementSetMessagingTimeout(window, 0.15)
        var visited = 0
        func walk(_ element: AXUIElement) -> String? {
            guard visited < 40 else { return nil }
            visited += 1
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            if let role = roleRef as? String, role == kAXTextAreaRole {
                var valueRef: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
                if status == .success, let text = valueRef as? String, !text.isEmpty {
                    return text
                }
                // 文本区读不到值：该分支无产出，继续找兄弟/子树
            }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { return nil }
            for child in children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(window)
    }
}
