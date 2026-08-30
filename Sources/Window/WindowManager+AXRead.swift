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

@MainActor
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
        let whAxStart = Date()
        var windowID: CGWindowID = 0
        let status = _AXUIElementGetWindow(window, &windowID)
        let found = status == .success && windowID != 0
        let whDurMs = elapsedMilliseconds(since: whAxStart)
        if whDurMs >= 50 {
            log("[WindowManager] windowHandle slow AX", level: .warn, fields: ["durationMs": String(whDurMs), "found": String(found)])
        }
        guard found else {
            return nil
        }
        return windowID
    }

    /// 读取 AX windowNumber（CGWindowNumber，跨 space move 稳定）。
    func windowNumber(for window: AXUIElement) -> Int? {
        // P-INST-44: AX windowNumber 读取耗时（slow-op ≥50ms warn）。
        let wnAxStart = Date()
        var numberRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, axWindowNumberAttribute as CFString, &numberRef)
        let wnDurMs = elapsedMilliseconds(since: wnAxStart)
        if wnDurMs >= 50 {
            log("[WindowManager] windowNumber slow AX", level: .warn, fields: ["durationMs": String(wnDurMs)])
        }
        guard status == .success, let number = numberRef as? NSNumber else {
            return nil
        }
        return number.intValue
    }

    /// 读取 AX 窗口标题。
    func title(of window: AXUIElement) -> String? {
        // P-INST-44: AX title 读取耗时（slow-op ≥50ms warn）。
        let titleAxStart = Date()
        var titleRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let titleDurMs = elapsedMilliseconds(since: titleAxStart)
        if titleDurMs >= 50 {
            log("[WindowManager] title(of:) slow AX", level: .warn, fields: ["durationMs": String(titleDurMs)])
        }
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
        let frameAxStart = Date()
        defer {
            log("[WindowManager] AX frame(of:) finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: frameAxStart))
            ])
        }
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
        let settableAxStart = Date()
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        let settableDurMs = elapsedMilliseconds(since: settableAxStart)
        if settableDurMs >= 50 {
            log("[WindowManager] isAttributeSettable slow AX", level: .warn, fields: ["attribute": attribute, "durationMs": String(settableDurMs)])
        }
        if status != .success {
            log("Settable check failed for \(attribute): \(status.rawValue)")
            return false
        }
        return settable.boolValue
    }
}
