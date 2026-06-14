import AppKit
import Foundation

@MainActor
extension SpaceController {

    func moveWindow(_ windowID: UInt32, toSpace space: SpaceIdentifier, focus: Bool, operationID: String? = nil, knownWindowInfo: YabaiWindowInfo? = nil) -> Bool {
        let op = operationID ?? "none"
        guard let spaceIndex = space.yabaiIndex else {
            log("[SpaceController] moveWindow: unsupported space identifier", level: .warn, fields: ["op": op])
            return false
        }
        AuditLogger.shared.record(
            eventType: "space_move",
            windowID: windowID,
            details: ["targetSpace": String(spaceIndex), "focus": String(focus), "op": op]
        )
        refreshAvailabilityIfNeeded()
        guard isEnabled else { return false }
        guard canControlSpaces else {
            markOperationError("Cannot move window to another space because cross-space control is unavailable", operationID: op)
            return false
        }

        guard let windowInfo = knownWindowInfo ?? queryWindow(windowID: windowID) else {
            log("[SpaceController] moveWindow aborted: window does not exist", level: .warn, fields: [
                "op": op, "windowID": String(windowID), "targetSpace": String(spaceIndex)
            ])
            return false
        }

        // Strategy 1: yabai 命令 — 优先。
        // focus=false 后 yabai `window --space` 不切用户视角、不触发 space 动画，SA 不阻塞，
        // 实测仅 ~29ms/fork（之前 focus=true 切 space 动画时 ~1014ms）。仅当窗口可被 yabai 管理时尝试。
        if windowInfo.isManageableByYabai {
            let result = runYabaiVariants(
                variants: [["-m", "window", "\(windowID)", "--space", "\(spaceIndex)"]],
                operation: "moveWindow(windowID=\(windowID), space=\(spaceIndex))",
                operationID: op
            )
            if result.success {
                if focus { _ = focusWindow(windowID, operationID: op, knownWindowInfo: windowInfo) }
                return true
            }
        } else {
            log("[SpaceController] moveWindow: skipping yabai (no AX ref)", level: .info, fields: [
                "op": op, "windowID": String(windowID)
            ])
        }

        // Strategy 2: NativeSpaceBridge (SLS) fallback — yabai 失败时。
        // 注意：SLSMoveWindowsToManagedSpace 需要 "universal owner connection"（yabai issue #2593），
        // yabai 经 SA 进程或 Dock sideload 获取。VibeFocus 是普通 GUI app，SLSMainConnectionID 返回
        // 普通 connection，权限不足 → SLS move 始终失败（result 返回垃圾值，非 0）。
        // 保留作为 yabai 不可用时的最后尝试，但预期失败（详见 NativeSpaceBridge.moveWindow log）。

        markOperationError("Failed to move window \(windowID) to space \(spaceIndex)", operationID: op)
        return false
    }

    func setWindowFloat(_ windowID: UInt32, operationID: String? = nil, knownWindowInfo: YabaiWindowInfo? = nil) {
        let op = operationID ?? "none"
        let startedAt = Date()
        var outcome = "unknown"
        // defer 汇总：所有退出路径（含各 skip）都记录耗时，消除 setWindowFloat 耗时盲区。
        defer {
            log("[SpaceController] setWindowFloat", fields: [
                "op": op,
                "windowID": String(windowID),
                "outcome": outcome,
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

        _ = runYabai(
            arguments: ["-m", "window", "\(windowID)", "--toggle", "float"],
            operation: "setWindowFloat",
            operationID: op
        )
        outcome = "toggled"
    }

    func focusWindow(_ windowID: UInt32, operationID: String? = nil, knownWindowInfo: YabaiWindowInfo? = nil) -> Bool {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else { return false }

        // 使用传入的窗口信息或查询缓存
        let info = knownWindowInfo ?? queryWindow(windowID: windowID)
        guard let info else {
            log("[SpaceController] focusWindow aborted: window does not exist", level: .warn, fields: [
                "op": op, "windowID": String(windowID)
            ])
            return false
        }

        // yabai 无法管理此窗口时，用 Carbon API 直接 focus
        if !info.isManageableByYabai {
            let carbonResult = WindowManager.shared.focusWindowByCGWindowID(windowID)
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
        if result.success { return true }
        // yabai focus 失败时也尝试 Carbon fallback
        let carbonResult = WindowManager.shared.focusWindowByCGWindowID(windowID)
        if carbonResult { return true }
        markOperationError(from: result.failure, fallback: "Failed to focus window \(windowID)", operationID: op)
        return false
    }

    func displayVisibleSpace(displayIndex: DisplayIdentifier?) -> SpaceIdentifier? {
        guard let idx = displayIndex?.yabaiIndex else { return nil }
        return visibleSpaceIndex(forDisplayIndex: idx)
    }
}
