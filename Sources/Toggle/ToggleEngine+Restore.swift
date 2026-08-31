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
        // P-INST-79: restore 端到端总耗时（defer 覆盖所有 return 含早期 lookup/query 失败路径；139 finished 仅成功路径汇总子阶段；lookup+query+move+float+apply+focusSpace 之和 + gaps；toggle/restore 核心）。
        #if PERF_INSTRUMENT
        let restoreStart = Date()
        defer {
            log("[ToggleEngine] restore finished", level: .debug, fields: [
                "windowID": String(windowID),
                "durationMs": String(elapsedMilliseconds(since: restoreStart))
            ])
        }
        #endif
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
        guard wm.findWindowByPID(record.pid, windowID: axLookupID) != nil else {
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

        // 4. Move back to original frame（2026-09-01 重构：float 脱管 → yabai --move/--resize 直写 origFrame）
        // 原 `yabai --space` 在 yabai v7 float 布局下静默失效（exit 0 但窗口不动，
        // Tests/AXMoveValidation.swift T3 断言实测）；frame 直写经断言验证跨 display 可靠，
        // macOS 窗口归属跟随物理位置自动回到源 display 的 visible space。
        // （局限：源 space 为源屏非可见 space 时，窗口回到源屏可见 space——yabai float 布局
        // 无精确 space 寻址能力，此为当前环境约束下的最优可达。）
        // queryMs 覆盖 currentSpaceIndex + queryWindow（移动前查询，命中缓存 ~0ms）。
        let queryStart = Date()
        // 记录移动前的 focused space — 用于检测 macOS 是否自动切换了 space
        let preMoveSpace = sc.currentSpaceIndex()
        let windowInfo = sc.queryWindow(windowID: axLookupID)
        let queryMs = elapsedMilliseconds(since: queryStart)
        var moveMs = 0
        // 4a. float 脱管（--toggle float 会触发 yabai 默认重摆，等 300ms 重摆落定再写目标 frame）
        if let info = windowInfo {
            let floatStart = Date()
            sc.setWindowFloat(axLookupID, operationID: trace, knownWindowInfo: info)
            usleep(300_000)
            moveMs = elapsedMilliseconds(since: floatStart)
        }
        // 4b. yabai --move abs + --resize abs 直写 origFrame（窗口归属跟随物理位置）
        var frameOK = false
        if record.sourceSpace > 0 || true {
            // sourceSpace=0（无 space 信息）时 origFrame 坐标仍有效——frame 直写不依赖 space 编号
            let moveStart = Date()
            frameOK = wm.moveWindowToFrameViaYabai(
                windowID: axLookupID,
                frame: record.origFrame,
                op: trace,
                stage: "restore"
            )
            moveMs += elapsedMilliseconds(since: moveStart)
            log("[ToggleEngine] restore: frame move result", fields: [
                "traceID": trace, "frameOK": String(frameOK),
                "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y)) \(Int(record.origFrame.width))x\(Int(record.origFrame.height))"
            ])
        }
        let moved = false  // 语义保留：不再使用 yabai space move（focusSpace 检测条件依赖）

        // 5./6. float 与 frame 写已合并到步骤 4（floatMs/frameOK）
        let floatMs = 0
        let applyMs = 0

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
