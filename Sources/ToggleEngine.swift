import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

/// Toggle Engine — 窗口 toggle/restore 的单一入口
///
/// 设计原则：
/// 1. 单一事实来源：所有 toggle state 只存 SQLite `windows` 表，不缓存到内存
/// 2. 确定性查找：用 windowID 直接查 SQLite，不走 PID/TTY/PPID 猜测链
/// 3. 原子操作：save 是一次 SQLite UPDATE，read 是一次 SELECT
@MainActor
final class ToggleEngine {

    static let shared = ToggleEngine()
    private init() {}

    private var store: WindowStateStore { WindowStateStore.shared }

    // MARK: - Save (Ctrl+Q 触发)

    /// 保存 toggle 快照 — 在 moveWindowToMainScreen 成功后调用
    func save(
        windowID: UInt32,
        pid: Int32,
        bundleIdentifier: String?,
        appName: String?,
        origFrame: CGRect,
        sourceSpace: Int,
        sourceDisplay: Int,
        sourceYabaiDisp: Int,
        sourceDispSpace: Int,
        targetFrame: CGRect,
        targetDisplay: Int,
        sessionID: String?
    ) {
        let record = ToggleRecord(
            windowID: windowID,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            origFrame: origFrame,
            sourceSpace: sourceSpace,
            sourceDisplay: sourceDisplay,
            sourceYabaiDisp: sourceYabaiDisp,
            sourceDispSpace: sourceDispSpace,
            targetFrame: targetFrame,
            targetDisplay: targetDisplay,
            toggledAt: Date(),
            sessionID: sessionID
        )

        store.saveToggleRecord(record)

        log("ToggleEngine.save", level: .info, fields: [
            "windowID": String(windowID),
            "sourceSpace": String(sourceSpace),
            "sourceDisplay": String(sourceDisplay),
            "sourceYabaiDisp": String(sourceYabaiDisp),
            "sourceDispSpace": String(sourceDispSpace),
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
            "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.size.width))x\(Int(targetFrame.size.height))"
        ])
    }

    // MARK: - Load (UserPromptSubmit 触发)

    /// 按 windowID 读取 toggle record
    func load(windowID: UInt32) -> ToggleRecord? {
        return store.loadToggleRecord(windowID: windowID)
    }

    // MARK: - Clear (Restore 后或窗口关闭时)

    /// 清除 toggle state
    func clear(windowID: UInt32) {
        store.clearToggleRecord(windowID: windowID)
        log("ToggleEngine.clear", fields: ["windowID": String(windowID)])
    }

    // MARK: - Restore 执行

    /// 执行恢复：移动窗口回原始位置 + 切换到原始 space
    @discardableResult
    func restore(windowID: UInt32, triggerSource: String) -> Bool {
        guard let record = load(windowID: windowID) else {
            log("ToggleEngine.restore: no toggle record found", level: .warn, fields: [
                "windowID": String(windowID)
            ])
            return false
        }

        log("ToggleEngine.restore: starting", level: .info, fields: [
            "windowID": String(windowID),
            "sourceSpace": String(record.sourceSpace),
            "sourceDisplay": String(record.sourceDisplay),
            "sourceYabaiDisp": String(record.sourceYabaiDisp),
            "sourceDispSpace": String(record.sourceDispSpace),
            "triggerSource": triggerSource
        ])

        let wm = WindowManager.shared

        // 1. 找到窗口 AX element
        guard let windowAX = wm.findWindowByPID(record.pid, windowID: record.windowID) else {
            log("ToggleEngine.restore: window AX element not found", level: .warn, fields: [
                "windowID": String(windowID),
                "pid": String(record.pid)
            ])
            return false
        }

        // 2. 获取当前 frame（验证用）
        guard let currentFrame = wm.frame(of: windowAX) else {
            log("ToggleEngine.restore: cannot get current frame", level: .warn)
            return false
        }

        // 3. 验证窗口确实在 target 位置附近
        if !record.isNearTarget(currentFrame: currentFrame) {
            log("ToggleEngine.restore: window moved from target, skipping restore", level: .warn, fields: [
                "windowID": String(windowID),
                "currentX": String(Int(currentFrame.origin.x)),
                "currentY": String(Int(currentFrame.origin.y)),
                "targetX": String(Int(record.targetFrame.origin.x)),
                "targetY": String(Int(record.targetFrame.origin.y))
            ])
            return false
        }

        // 4. 先切换到原始 space（必须在 apply frame 之前，因为坐标是相对于目标屏幕的）
        switchToOriginalSpace(record: record, windowAX: windowAX, triggerSource: triggerSource)

        // 5. 切换完成后重新获取 AX element（space 切换可能使旧引用失效）
        let restoreAX = wm.findWindowByPID(record.pid, windowID: record.windowID) ?? windowAX

        // 6. 设置恢复 frame（此时窗口已在正确的屏幕/工作区上，坐标系统匹配）
        let restored = wm.apply(frame: record.origFrame, to: restoreAX, operationID: "toggle_engine_restore", stage: "restore_orig")
        if !restored {
            log("ToggleEngine.restore: frame apply failed", level: .error)
        }

        log("ToggleEngine.restore: success", level: .info, fields: [
            "windowID": String(windowID),
            "restoredTo": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))"
        ])
        return true
    }

    // MARK: - Space Switching

    /// 切换到窗口的原始 space
    private func switchToOriginalSpace(record: ToggleRecord, windowAX: AXUIElement, triggerSource: String) {
        let spaceController = SpaceController.shared

        // 用 captureSpaceContext 获取窗口当前 space
        let currentContext = spaceController.captureSpaceContext(windowID: record.windowID, operationID: "toggle_engine_space_check")
        guard let currentSpace = currentContext.sourceSpaceIndex else {
            log("ToggleEngine.switchToOriginalSpace: cannot query current space", level: .debug)
            return
        }

        let targetSpace = record.sourceSpace
        guard currentSpace != targetSpace else {
            log("ToggleEngine.switchToOriginalSpace: already on target space", level: .debug, fields: [
                "space": String(targetSpace)
            ])
            return
        }

        log("ToggleEngine.switchToOriginalSpace: switching", fields: [
            "from": String(currentSpace),
            "to": String(targetSpace),
            "sourceYabaiDisp": String(record.sourceYabaiDisp),
            "sourceDispSpace": String(record.sourceDispSpace)
        ])

        // 使用 SpaceController.moveWindow — 包含完整 fallback 链：
        // 1. NativeSpaceBridge (CGS private API)
        // 2. yabai -m window --space (scripting-addition)
        // 3. NativeSpaceBridge fallback
        let moved = spaceController.moveWindow(
            record.windowID,
            toSpaceIndex: targetSpace,
            focus: triggerSource == "carbon_hotkey",
            operationID: "toggle_engine_space_switch"
        )

        if !moved {
            // moveWindow 三策略全部失败 — 用 focusSpace AppleScript 兜底
            // AppleScript 发送 Ctrl+Left/Right 切换用户视角，窗口会随当前 space 一起移动
            log("ToggleEngine.switchToOriginalSpace: moveWindow failed, trying focusSpace fallback", level: .warn, fields: [
                "windowID": String(record.windowID),
                "targetSpace": String(targetSpace),
                "currentSpace": String(currentSpace)
            ])

            let steps = targetSpace - currentSpace
            let focusOK = NativeSpaceBridge.focusSpace(steps: steps, operationID: "toggle_engine_focusSpace_fallback")
            if !focusOK {
                log("ToggleEngine.switchToOriginalSpace: focusSpace also failed", level: .error, fields: [
                    "windowID": String(record.windowID),
                    "steps": String(steps)
                ])
                return
            }

            log("ToggleEngine.switchToOriginalSpace: focusSpace succeeded", level: .info, fields: [
                "steps": String(steps)
            ])
            usleep(300_000)
        } else {
            // moveWindow 成功，等待动画
            usleep(200_000)
        }

        // hotkey 触发时确保用户视角跟随
        if triggerSource == "carbon_hotkey" {
            let steps = targetSpace - currentSpace
            if steps != 0 {
                _ = NativeSpaceBridge.focusSpace(steps: steps)
                usleep(400_000)
            }
        }
    }
}
