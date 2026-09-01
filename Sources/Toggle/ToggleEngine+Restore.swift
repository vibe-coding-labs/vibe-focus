import Foundation
import Cocoa

// MARK: - Restore Logic (Simplified)
//
// Design: 源屏预切回 → float 脱管 → yabai --move/--resize 直写 origFrame → 视角守卫。
// One shot, no retries. The old mechanism had 4 strategies, polling loops, a watchdog,
// and 642 lines to do what these steps accomplish.
//
// 历史注：2026-09-01 起不再用 yabai `window --space`（v7 float 布局下静默失效，
// exit 0 但窗口不动，Tests/AXMoveValidation.swift T3 断言实测）。

@MainActor
extension ToggleEngine {

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

        // 3. Resolve AX window（record 按 windowID 加载，两者恒等；存在性探测兼防窗口已关）
        let lookupStart = Date()
        guard wm.findWindowByPID(record.pid, windowID: windowID) != nil else {
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
            "origFrame": QuartzRect(record.origFrame).description,
            "targetFrame": QuartzRect(record.targetFrame).description
        ])

        // 视角基准：必须在 4-pre 切换源屏之前采集（否则守卫看到的是切换后的 space，漏切回）。
        // 记录移动前的 focused space — 用于检测 macOS 是否自动切换了 space
        let preMoveSpace = sc.currentSpaceIndex()

        // 4-pre. space 精确恢复前置（ToggleRecord 的 source_space/source_display 列启用）：
        // record 记录了窗口原始所属的 space（record.sourceSpace）与 display（record.sourceYabaiDisp）。
        // frame 直写只能落到"目标屏当前可见 space"——若源屏已被用户切到别的 space，窗口会落错。
        // 处理：源屏可见 space ≠ sourceSpace 时，先把源屏切回 sourceSpace（聚焦该 space 上的
        // 可管理窗口带动视角切换，refocusWindowOnSpace 不依赖 SA），窗口归属即精确。
        // sourceSpace 上无可聚焦窗口（空 space）时无法切换，退化为落源屏可见 space + WARN。
        if record.sourceSpace > 0, record.sourceYabaiDisp > 0,
           let visibleOnSourceDisplay = sc.visibleSpaceIndex(forDisplayIndex: record.sourceYabaiDisp)?.yabaiIndex,
           visibleOnSourceDisplay != record.sourceSpace {
            log("[ToggleEngine] restore: source display is on a different space, switching it back", level: .info, fields: [
                "traceID": trace, "windowID": String(windowID),
                "sourceDisplay": String(record.sourceYabaiDisp),
                "visibleSpace": String(visibleOnSourceDisplay),
                "sourceSpace": String(record.sourceSpace)
            ])
            let switchStart = Date()
            let switched = sc.refocusWindowOnSpace(record.sourceSpace, operationID: trace)
            if switched {
                usleep(WindowSettle.yabaiFrameWriteSettleMicros)  // 等视角切换与 yabai 状态落定，再写窗口 frame
            }
            log("[ToggleEngine] restore: source display space switch result", level: switched ? .info : .warn, fields: [
                "traceID": trace, "switched": String(switched),
                "durationMs": String(elapsedMilliseconds(since: switchStart))
            ])
        }

        // 4. Move back to original frame（2026-09-01 重构：float 脱管 → yabai --move/--resize 直写 origFrame）
        // 原 `yabai --space` 在 yabai v7 float 布局下静默失效（exit 0 但窗口不动，
        // Tests/AXMoveValidation.swift T3 断言实测）；frame 直写经断言验证跨 display 可靠，
        // macOS 窗口归属跟随物理位置自动回到源 display 的 visible space。
        // queryMs 覆盖 currentSpaceIndex + queryWindow（移动前查询，命中缓存 ~0ms）。
        let queryStart = Date()
        let windowInfo = sc.queryWindow(windowID: windowID)
        let queryMs = elapsedMilliseconds(since: queryStart)
        var moveMs = 0
        // 4a. float 脱管（--toggle float 会触发 yabai 默认重摆，等 300ms 重摆落定再写目标 frame）
        if let info = windowInfo {
            let floatStart = Date()
            sc.setWindowFloat(windowID, operationID: trace, knownWindowInfo: info)
            usleep(WindowSettle.floatRelayoutSettleMicros)
            moveMs = elapsedMilliseconds(since: floatStart)
        }
        // 4b. yabai --move abs + --resize abs 直写 origFrame（窗口归属跟随物理位置）。
        // sourceSpace=0（无 space 信息）时 origFrame 坐标仍有效——frame 直写不依赖 space 编号。
        var frameOK = false
        let moveStart = Date()
        frameOK = wm.moveWindowToFrameViaYabai(
            windowID: windowID,
            frame: record.origFrame,
            op: trace,
            stage: "restore"
        )
        moveMs += elapsedMilliseconds(since: moveStart)
        log("[ToggleEngine] restore: frame move result", fields: [
            "traceID": trace, "frameOK": String(frameOK),
            "origFrame": QuartzRect(record.origFrame).description
        ])

        // 5. 视角守卫：frame 直写会把 macOS 键盘焦点/视角跟随到目标 display
        // （实测 restore 后 preSpace=1 → postSpace=5，用户被拖离原屏）。
        // 切回分两层，按可靠性排序：
        //   1) yabai space --focus 精确切回（依赖 SA；SA 失效时报
        //      "error with the scripting-addition"，本机已失效）；
        //   2) 聚焦原 space 上的任意可管理窗口（AX/CG 通道不依赖 SA，实测可靠；原
        //      CGEvent 方向键法在 separate-Spaces 下无法跨 display，已废弃）。
        var focusSpaceMs = 0
        if let preMoveSpace {
            let postMoveSpace = sc.currentSpaceIndex()
            if let postMoveSpace, postMoveSpace != preMoveSpace {
                log("[ToggleEngine] restore: macOS auto-switched space, refocusing original screen", level: .info, fields: [
                    "traceID": trace, "preSpace": String(preMoveSpace),
                    "postSpace": String(postMoveSpace)
                ])
                let focusSpaceStart = Date()
                var refocused = sc.focusSpace(.yabaiIndex(preMoveSpace), operationID: trace)
                if !refocused {
                    // SA 失效环境：聚焦原 space 上的窗口带动视角回切
                    refocused = sc.refocusWindowOnSpace(preMoveSpace, excludingWindowID: windowID, operationID: trace)
                }
                if refocused {
                    // space 切换后窗口位置可能已变，清除查询缓存
                    sc.clearQueryCache()
                }
                focusSpaceMs = elapsedMilliseconds(since: focusSpaceStart)
            }
        }

        // 6. Clear record
        clear(windowID: record.windowID)

        log("[ToggleEngine] restore: completed", fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "targetSpace": String(record.sourceSpace),
            "frameOK": String(frameOK),
            "origFrame": QuartzRect(record.origFrame).originDescription,
            "lookupMs": String(lookupMs),
            "queryMs": String(queryMs),
            "moveMs": String(moveMs),
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
