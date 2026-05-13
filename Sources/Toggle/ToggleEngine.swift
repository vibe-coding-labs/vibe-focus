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
        // 验证 origFrame 不在主屏上 — 如果 origFrame 在主屏，说明数据异常
        let mainScreen = NSScreen.screens.first { $0.frame.origin == .zero }
        if let mainScreenFrame = mainScreen?.frame {
            let origCenter = CGPoint(x: origFrame.midX, y: origFrame.midY)
            if mainScreenFrame.contains(origCenter) {
                log(
                    "[ToggleEngine] save rejected: origFrame is on main screen (corrupted data)",
                    level: .warn,
                    fields: [
                        "windowID": String(windowID),
                        "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
                        "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.size.width))x\(Int(targetFrame.size.height))",
                        "sourceSpace": String(describing: sourceSpace),
                        "sourceYabaiDisp": String(describing: sourceYabaiDisp)
                    ]
                )
                return
            }
        }

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
    func restore(windowID: UInt32, triggerSource: String, traceID: String? = nil) -> Bool {
        let trace = traceID ?? makeOperationID(prefix: "te")
        guard let record = load(windowID: windowID) else {
            log("ToggleEngine.restore: no toggle record found", level: .warn, fields: [
                "traceID": trace,
                "windowID": String(windowID)
            ])
            return false
        }

        log("ToggleEngine.restore: starting", level: .info, fields: [
            "traceID": trace,
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
                "traceID": trace,
                "windowID": String(windowID),
                "pid": String(record.pid)
            ])
            return false
        }

        // 2. 获取当前 frame（验证用）
        guard let currentFrame = wm.readAccurateFrame(windowID: windowID, axElement: windowAX) else {
            log("ToggleEngine.restore: cannot get current frame", level: .warn, fields: [
                "traceID": trace
            ])
            return false
        }

        // 3. 验证窗口确实在 target 位置附近
        if !record.isNearTarget(currentFrame: currentFrame) {
            let xOffset = abs(currentFrame.origin.x - record.targetFrame.origin.x)
            let yOffset = abs(currentFrame.origin.y - record.targetFrame.origin.y)
            log("ToggleEngine.restore: window moved from target, skipping restore", level: .warn, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "currentFrame": "\(Int(currentFrame.origin.x)),\(Int(currentFrame.origin.y)) \(Int(currentFrame.size.width))x\(Int(currentFrame.size.height))",
                "targetFrame": "\(Int(record.targetFrame.origin.x)),\(Int(record.targetFrame.origin.y)) \(Int(record.targetFrame.size.width))x\(Int(record.targetFrame.size.height))",
                "xOffset": String(Int(xOffset)),
                "yOffset": String(Int(yOffset)),
                "tolerance": "200"
            ])
            return false
        }

        // 4. 先切换到原始 space（必须在 apply frame 之前，因为坐标是相对于目标屏幕的）
        let spaceSwitched = switchToOriginalSpace(record: record, windowAX: windowAX, triggerSource: triggerSource, traceID: trace)
        if !spaceSwitched {
            log("ToggleEngine.restore: space switch failed, aborting restore to avoid applying wrong-screen coordinates", level: .error, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "targetSpace": String(record.sourceSpace),
                "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y)) \(Int(record.origFrame.size.width))x\(Int(record.origFrame.size.height))"
            ])
            return false
        }

        // 5. 切换完成后重新获取 AX element（space 切换可能使旧引用失效）
        guard let restoreAX = wm.findWindowByPID(record.pid, windowID: record.windowID) else {
            log("ToggleEngine.restore: AX element lost after space switch, cannot continue", level: .error, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "pid": String(record.pid)
            ])
            return false
        }

        // 6. 设置恢复 frame（此时窗口已在正确的屏幕/工作区上，坐标系统匹配）
        let restored = wm.apply(frame: record.origFrame, to: restoreAX, operationID: trace, stage: "restore_orig")
        if !restored {
            log("ToggleEngine.restore: frame apply failed, returning false", level: .error, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y)) \(Int(record.origFrame.size.width))x\(Int(record.origFrame.size.height))"
            ])
            return false
        }

        // 验证窗口确实到达了目标 space（防御性检查）
        let postRestoreSpace = SpaceController.shared.windowSpaceIndex(windowID: windowID)
        if let postSpace = postRestoreSpace, postSpace != record.sourceSpace {
            log("ToggleEngine.restore: window ended up on wrong space after restore", level: .error, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "expectedSpace": String(record.sourceSpace),
                "actualSpace": String(postSpace)
            ])
            return false
        }

        log("ToggleEngine.restore: success", level: .info, fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "restoredTo": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))"
        ])
        return true
    }

    // MARK: - Space Switching

    /// 切换到窗口的原始 space
    /// 核心逻辑：查询目标 display 当前可见 space，如果已经是目标 space 则跳过切换
    private func switchToOriginalSpace(record: ToggleRecord, windowAX: AXUIElement, triggerSource: String, traceID: String) -> Bool {
        let spaceController = SpaceController.shared
        let targetSpace = record.sourceSpace
        let targetDisplay = record.sourceYabaiDisp

        // 查询目标 display 当前显示的 space（不是窗口所在的 space）
        let displayCurrentSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)

        log("ToggleEngine.switchToOriginalSpace: space check", fields: [
            "traceID": traceID,
            "targetSpace": String(targetSpace),
            "targetDisplay": String(describing: targetDisplay),
            "displayCurrentSpace": String(describing: displayCurrentSpace),
            "triggerSource": triggerSource
        ])

        if let current = displayCurrentSpace, current == targetSpace {
            log("ToggleEngine.switchToOriginalSpace: target display already on correct space, skipping switch", fields: [
                "traceID": traceID,
                "space": String(targetSpace)
            ])
            // display 已经在正确 space，只需移动窗口到该 space
            let moved = spaceController.moveWindow(
                record.windowID,
                toSpaceIndex: targetSpace,
                focus: false,
                operationID: traceID
            )
            if !moved {
                log("ToggleEngine.switchToOriginalSpace: moveWindow failed (display already on correct space)", level: .warn, fields: [
                    "traceID": traceID,
                    "windowID": String(record.windowID),
                    "targetSpace": String(targetSpace)
                ])
                return false
            }
            // 验证窗口真正到达目标 space
            let started = Date()
            var windowOnTarget = false
            while Date().timeIntervalSince(started) < 0.2 {
                if let s = spaceController.windowSpaceIndex(windowID: record.windowID), s == targetSpace {
                    windowOnTarget = true
                    break
                }
                usleep(20_000)
            }
            if !windowOnTarget {
                log("ToggleEngine.switchToOriginalSpace: window did not reach target space after moveWindow", level: .warn, fields: [
                    "traceID": traceID,
                    "windowID": String(record.windowID),
                    "targetSpace": String(targetSpace)
                ])
                return false
            }
            return true
        }

        log("ToggleEngine.switchToOriginalSpace: need space switch", fields: [
            "traceID": traceID,
            "displayCurrentSpace": String(describing: displayCurrentSpace),
            "targetSpace": String(targetSpace),
            "targetDisplay": String(describing: targetDisplay),
            "sourceYabaiDisp": String(record.sourceYabaiDisp)
        ])

        // 目标 display 不在正确 space — 需要先切换 display 的 space 再移动窗口
        if let current = displayCurrentSpace, current != targetSpace {
            let switchStart = Date()
            let switched = spaceController.switchDisplayToSpace(
                targetSpace: targetSpace,
                operationID: traceID
            )
            log("ToggleEngine.switchToOriginalSpace: switchDisplayToSpace result", fields: [
                "traceID": traceID,
                "switched": String(switched),
                "targetSpace": String(targetSpace),
                "switchDisplayMs": String(elapsedMilliseconds(since: switchStart))
            ])
            if switched {
                // 轮询等待 display 到达目标 space（替代固定 400ms sleep）
                let td = targetDisplay
                let started = Date()
                while Date().timeIntervalSince(started) < 0.4 {
                    if spaceController.displayVisibleSpace(displayIndex: td) == targetSpace { break }
                    usleep(30_000)
                }
            } else {
                log("ToggleEngine.switchToOriginalSpace: switchDisplayToSpace failed", level: .warn, fields: [
                    "traceID": traceID,
                    "targetSpace": String(targetSpace)
                ])
                return false
            }
        } else {
            log("ToggleEngine.switchToOriginalSpace: could not determine display current space, aborting", level: .warn, fields: [
                "traceID": traceID,
                "targetDisplay": String(targetDisplay)
            ])
            return false
        }
        let moveStart = Date()
        let moved = spaceController.moveWindow(
            record.windowID,
            toSpaceIndex: targetSpace,
            focus: triggerSource == "carbon_hotkey",
            operationID: traceID
        )
        log("ToggleEngine.switchToOriginalSpace: moveWindow result", fields: [
            "traceID": traceID,
            "moved": String(moved),
            "moveWindowMs": String(elapsedMilliseconds(since: moveStart))
        ])

        if moved {
            // 快速验证窗口已在目标 space（替代固定 200ms）
            let started = Date()
            var windowOnTarget = false
            while Date().timeIntervalSince(started) < 0.2 {
                if let s = spaceController.windowSpaceIndex(windowID: record.windowID), s == targetSpace {
                    windowOnTarget = true
                    break
                }
                usleep(20_000)
            }
            if !windowOnTarget {
                log("ToggleEngine.switchToOriginalSpace: window did not reach target space after moveWindow", level: .warn, fields: [
                    "traceID": traceID,
                    "windowID": String(record.windowID),
                    "targetSpace": String(targetSpace)
                ])
                return false
            }
            return true
        } else {
            log("ToggleEngine.switchToOriginalSpace: moveWindow failed, aborting restore", level: .warn, fields: [
                "traceID": traceID,
                "windowID": String(record.windowID),
                "targetSpace": String(targetSpace)
            ])
            return false
        }
    }
}
