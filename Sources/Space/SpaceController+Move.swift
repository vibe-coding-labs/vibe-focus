import AppKit
import Foundation

@MainActor
extension SpaceController {

    // MARK: 历史注（2026-09-01 清理）
    // moveWindow(toSpace:) 已删除：其 Strategy 1（yabai `window --space`）在 v7 float
    // 布局下静默失效（exit 0 但窗口不动，Tests/AXMoveValidation.swift T3 断言实测），
    // Strategy 2（SLS move）因权限不足从未真正可用。跨屏移动统一走
    // WindowManager.moveWindowToFrameViaYabai（float 脱管 → settle → frame 直写 + 读回验证）。

    func setWindowFloat(_ windowID: UInt32, operationID: String? = nil, knownWindowInfo: YabaiWindowInfo? = nil) {
        let op = operationID ?? "none"
        let startedAt = Date()
        var outcome = "unknown"
        // P-INST-13: yabai toggle float fork 耗时（runYabai logSuccess=false，fast<180ms 不记，此处补 forkMs）。
        var forkMs = 0
        // defer 汇总：所有退出路径（含各 skip）都记录耗时，消除 setWindowFloat 耗时盲区。
        defer {
            log("[SpaceController] setWindowFloat", fields: [
                "op": op,
                "windowID": String(windowID),
                "outcome": outcome,
                "forkMs": String(forkMs),
                "durationMs": String(elapsedMilliseconds(since: startedAt))
            ])
        }

        guard isEnabled else {
            outcome = "skipped_disabled"
            return
        }

        // 使用传入的窗口信息或查询缓存
        let info = knownWindowInfo ?? queryWindow(windowID: windowID)
        if let info {
            if info.isFloating {
                outcome = "skipped_already_floating"
                return
            }
            // yabai 无法管理此窗口时，float 切换无意义且必定失败
            if !info.isManageableByYabai {
                outcome = "skipped_unmanaged"
                log("setWindowFloat: skipping (no AX ref, yabai can't manage)", level: .info, fields: [
                    "op": op, "windowID": String(windowID)
                ])
                return
            }
        } else {
            outcome = "skipped_query_nil"
            log("setWindowFloat: queryWindow returned nil, skipping toggle", level: .warn, fields: [
                "op": op, "windowID": String(windowID)
            ])
            return
        }

        let floatForkStart = Date()
        _ = runYabai(
            arguments: ["-m", "window", "\(windowID)", "--toggle", "float"],
            operation: "setWindowFloat",
            operationID: op
        )
        forkMs = elapsedMilliseconds(since: floatForkStart)
        outcome = "toggled"
    }

    func focusWindow(_ windowID: UInt32, operationID: String? = nil, knownWindowInfo: YabaiWindowInfo? = nil) -> Bool {
        let op = operationID ?? "none"
        // P-INST-53: focusWindow 总耗时（queryWindow P-INST-6 + runYabaiVariants P-INST-27 + Carbon fallback；顶层归因，含各 abort/success 路径）。
        let fcStart = Date()
        var fcOutcome = "unknown"
        defer {
            log("[SpaceController] focusWindow finished", fields: [
                "op": op, "windowID": String(windowID),
                "outcome": fcOutcome,
                "durationMs": String(elapsedMilliseconds(since: fcStart))
            ])
        }
        refreshAvailabilityIfNeeded()
        guard isEnabled else { fcOutcome = "disabled"; return false }

        // 使用传入的窗口信息或查询缓存
        let info = knownWindowInfo ?? queryWindow(windowID: windowID)
        guard let info else {
            fcOutcome = "no_window"
            log("[SpaceController] focusWindow aborted: window does not exist", level: .warn, fields: [
                "op": op, "windowID": String(windowID)
            ])
            return false
        }

        // yabai 无法管理此窗口时，用 Carbon API 直接 focus
        if !info.isManageableByYabai {
            let carbonResult = WindowManager.shared.focusWindowByCGWindowID(windowID)
            fcOutcome = carbonResult ? "carbon_ok" : "carbon_failed"
            log("[SpaceController] focusWindow via Carbon fallback", level: carbonResult ? .info : .warn, fields: [
                "op": op, "windowID": String(windowID), "result": String(carbonResult)
            ])
            return carbonResult
        }

        let result = runYabaiVariants(
            variants: [["-m", "window", "--focus", "\(windowID)"]],
            operation: "focusWindow(\(windowID))",
            operationID: op
        )
        if result.success { fcOutcome = "yabai_ok"; return true }
        // yabai focus 失败时也尝试 Carbon fallback
        let carbonResult = WindowManager.shared.focusWindowByCGWindowID(windowID)
        if carbonResult { fcOutcome = "carbon_fallback_ok"; return true }
        fcOutcome = "all_failed"
        markOperationError(from: result.failure, fallback: "Failed to focus window \(windowID)", operationID: op)
        return false
    }
}
