import Foundation
import Cocoa

// MARK: - Restore Logic (Simplified)
//
// Design: yabai space move → float → AX frame. One shot, no retries.
// The old mechanism had 4 strategies, polling loops, a watchdog, and 642 lines
// to do what these 3 steps accomplish.

@MainActor
extension ToggleEngine {

    /// Pure decision: which record to use for restore?
    /// Returns record or nil if not found. No PID fallback — same-PID windows
    /// (e.g. all iTerm2 windows) would return the wrong record.
    static func resolveRestoreRecord(
        windowID: UInt32,
        loadByWindowID: (UInt32) -> ToggleRecord?
    ) -> ToggleRecord? {
        return loadByWindowID(windowID)
    }

    @discardableResult
    func restore(windowID: UInt32, triggerSource: String, traceID: String? = nil) -> Bool {
        let trace = traceID ?? makeOperationID(prefix: "te")

        // 1. Load record — windowID only, no PID fallback
        guard let record = load(windowID: windowID) else {
            log("[ToggleEngine] restore: no toggle record", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID)
            ])
            return false
        }

        let wm = WindowManager.shared
        let sc = SpaceController.shared

        // 3. Resolve AX window
        let lookupStart = Date()
        let axLookupID = (record.windowID != windowID) ? windowID : record.windowID
        guard let windowAX = wm.findWindowByPID(record.pid, windowID: axLookupID) else {
            log("[ToggleEngine] restore: AX window not found", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID), "pid": String(record.pid)
            ])
            return false
        }
        let lookupMs = elapsedMilliseconds(since: lookupStart)

        log("[ToggleEngine] restore: starting", fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "recordWindowID": String(record.windowID),
            "pid": String(record.pid),
            "sourceSpace": String(record.sourceSpace),
            "triggerSource": triggerSource,
            "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y)) \(Int(record.origFrame.width))x\(Int(record.origFrame.height))",
            "targetFrame": "\(Int(record.targetFrame.origin.x)),\(Int(record.targetFrame.origin.y)) \(Int(record.targetFrame.width))x\(Int(record.targetFrame.height))"
        ])

        // 4. Move to original space via yabai (skip if sourceSpace=0 — no space info available)
        var moved = false
        // queryMs 覆盖 currentSpaceIndex + queryWindow（移动前查询，命中缓存 ~0ms）。
        let queryStart = Date()
        // 记录 AX frame set 前的 focused space — 用于检测 macOS 是否自动切换了 space
        let preMoveSpace = sc.currentSpaceIndex()
        // 移动前查询一次窗口信息（toggle 开始已查询并缓存，此处命中缓存 ~0ms），
        // 复用给 moveWindow 和 setWindowFloat，避免空间移动后再 queryWindow。
        // space 切换后 yabai 卡顿，移动后 queryWindow 实测 ~1s fork（op=181 seq=198）。
        // 安全性：isFloating / isManageableByYabai 跨 space 保持不变 —— toggle 时已 float
        // 的窗口移动后仍 float，setWindowFloat 据此正确跳过；未 float 的会正确执行 toggle。
        let windowInfo = sc.queryWindow(windowID: axLookupID)
        let queryMs = elapsedMilliseconds(since: queryStart)
        var moveMs = 0
        if record.sourceSpace > 0 {
            // focus=false：restore 是"把窗口送回原位"，用户视角留主屏继续工作。
            // moveWindow 内部的 focusWindow(yabai window --focus) 会切换用户 space 触发
            // macOS 动画 + SA 阻塞 ~1s（op=186 实测 1019ms）—— 这是 restore 路径最后的卡顿源。
            // SLS move 只移窗口不切用户视角，配合 focus=false 用户始终留主屏。
            // macOS 自动切 space 的兜底由下方 line 101-114 的 focusSpace 切回处理。
            let moveStart = Date()
            moved = sc.moveWindow(
                axLookupID,
                toSpace: .yabai(record.sourceSpace),
                focus: false,
                operationID: trace,
                knownWindowInfo: windowInfo
            )
            moveMs = elapsedMilliseconds(since: moveStart)
            log("[ToggleEngine] restore: space move result", fields: [
                "traceID": trace, "moved": String(moved), "sourceSpace": String(record.sourceSpace)
            ])
        } else {
            log("[ToggleEngine] restore: sourceSpace=0, skipping yabai space move (no space info)", fields: [
                "traceID": trace, "windowID": String(windowID)
            ])
        }

        // 5. Float on target space — prevents yabai from tiling
        // 复用移动前 windowInfo，省去移动后的 queryWindow fork
        let floatStart = Date()
        sc.setWindowFloat(axLookupID, operationID: trace, knownWindowInfo: windowInfo)
        let floatMs = elapsedMilliseconds(since: floatStart)

        // 6. Apply original frame via AX
        // 单次模式：restore 前已 setWindowFloat，yabai 不会 re-tile，无需重试验证。
        // space 动画期间 AX write 已达物理下限，重试循环只会累积延迟。
        let applyStart = Date()
        if !wm.apply(frame: record.origFrame, to: windowAX, operationID: trace, stage: "restore", maxAttempts: 1) {
            log("[ToggleEngine] restore: AX frame apply failed", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID)
            ])
        }
        let applyMs = elapsedMilliseconds(since: applyStart)

        // 6b. 检测 macOS 自动切换 space（AX frame set 把焦点窗口移到了其他 display）
        // 当 yabai/space move 都失败时，AX 设置坐标会触发 macOS 自动跟随到目标 space，
        // 导致用户视角从 main screen 跳到 secondary screen。这里检测并切回。
        var focusSpaceMs = 0
        if !moved, let preMoveSpace {
            let postMoveSpace = sc.currentSpaceIndex()
            if let postMoveSpace, postMoveSpace != preMoveSpace {
                let steps = preMoveSpace - postMoveSpace
                log("[ToggleEngine] restore: macOS auto-switched space, switching back", level: .info, fields: [
                    "traceID": trace, "preSpace": String(preMoveSpace),
                    "postSpace": String(postMoveSpace), "steps": String(steps)
                ])
                let focusSpaceStart = Date()
                if NativeSpaceBridge.focusSpace(steps: steps, operationID: trace) {
                    // 清除 queryWindow 缓存，因为 space 切换后窗口位置可能已变
                    sc.clearQueryCache()
                }
                focusSpaceMs = elapsedMilliseconds(since: focusSpaceStart)
            }
        }

        // 7. Clear record
        clear(windowID: record.windowID)

        log("[ToggleEngine] restore: completed", fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "targetSpace": String(record.sourceSpace),
            "spaceMoveResult": String(moved),
            "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))",
            "lookupMs": String(lookupMs),
            "queryMs": String(queryMs),
            "moveMs": String(moveMs),
            "floatMs": String(floatMs),
            "applyMs": String(applyMs),
            "focusSpaceMs": String(focusSpaceMs)
        ])

        AuditLogger.shared.record(
            eventType: "restore_success",
            windowID: windowID,
            pid: record.pid,
            details: ["triggerSource": triggerSource, "targetSpace": String(record.sourceSpace)]
        )

        return true
    }
}
