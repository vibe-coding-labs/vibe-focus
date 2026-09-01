import AppKit
import Foundation

@MainActor
extension WindowManager {

    /// Restore the focused window to its pre-toggle position.
    ///
    /// This is the restore half of the toggle operation. It:
    /// 1. Identifies the window to restore（优先复用 toggle 入口的解析结果）
    /// 2. Delegates to `ToggleEngine.restore()` for actual execution
    ///
    /// **Important:** Execution logic lives exclusively in `ToggleEngine.restore()`.
    /// This method only does window identification before delegating.
    /// See `feedback_single_restore_path` for the architectural rationale.
    ///
    /// ## 场景
    /// - 仅 toggle() 的 .restore 分支调用；windowID 必传 toggle 入口已解析的
    ///   resolution.windowID——此处重新走 AX focusedWindow 是 toggle 的第 3 次
    ///   焦点解析（副屏阻塞 1.5s+，违反 toggle 头注释"禁止中途重新解析焦点"铁律，
    ///   2026-09-01 重构消除）。windowID==nil（理论不可达）时保留 AX 兜底。
    ///
    /// - Parameters:
    ///   - operationID: Unique identifier for this operation (auto-generated if nil)
    ///   - triggerSource: Origin of the restore (hotkey, hook, etc.)
    ///   - windowID: toggle 入口已解析的焦点窗口 CGWindowID
    func restore(operationID: String? = nil, triggerSource: String = "unknown", windowID: UInt32? = nil) {
        // P-INST-116: restore 委托路径总耗时（frontmostApplication + focusedWindow AX P-INST-52 + windowHandle AX + shouldRestore 决策 P-INST-76 + 委托 ToggleEngine.restore P-INST-79；memory feedback_single_restore_path：WindowManager.restore 做前置验证后委托，执行逻辑只在 ToggleEngine.restore；startedAt/finalDurationMs 已存在，此标记补全归因）。
        let op = operationID ?? makeOperationID(prefix: "restore")
        let startedAt = Date()
        // 注意：updateCrashSnapshotFromRuntime、logRuntimeStateSnapshot、AX 权限检查、
        // isWindowOnMainScreen 已在 toggle() 中完成，此处不再重复。
        // restore() 唯一调用者是 toggle()，所有前置检查已由 toggle() 完成。

        let currentWindowID: UInt32
        if let resolved = windowID {
            currentWindowID = resolved
        } else {
            guard let frontApp = NSWorkspace.shared.frontmostApplication,
                  let focusedWindow = focusedWindow(for: frontApp.processIdentifier),
                  let resolvedID = windowHandle(for: focusedWindow) else {
                log(
                    "[WindowManager] restore failed: cannot identify focused window",
                    level: .error,
                    fields: ["op": op]
                )
                return
            }
            currentWindowID = resolvedID
        }

        log(
            "[WindowManager] restore started",
            fields: [
                "op": op,
                "source": triggerSource,
                "windowID": String(currentWindowID)
            ]
        )

        // 2. 委托 ToggleEngine 执行 restore（唯一执行入口）
        // ToggleEngine 内部处理：load record → validate → 源屏预切回 → float → frame 直写 → 视角守卫
        log("[WindowManager+Restore] delegating to ToggleEngine.restore", level: .debug, fields: [
            "op": op,
            "windowID": String(currentWindowID),
            "triggerSource": triggerSource
        ])
        let engine = ToggleEngine.shared
        let restoreSucceeded = engine.restore(
            windowID: currentWindowID,
            triggerSource: triggerSource,
            traceID: op
        )

        guard restoreSucceeded else {
            log("[WindowManager] restore failed: ToggleEngine.restore returned false", level: .error, fields: [
                "op": op,
                "windowID": String(currentWindowID)
            ])
            CrashContextRecorder.shared.record("restore_failed_engine op=\(op)")
            return
        }

        // 3. ToggleEngine.restore() 已自动清除 toggle record 并写 restore_success 审计事件
        //    （审计唯一来源；此前这里再写一条 details 不同的同名事件，消费者无法区分）

        let finalDurationMs = elapsedMilliseconds(since: startedAt)
        log(
            "[WindowManager] restore finished",
            fields: [
                "op": op,
                "outcome": "restored",
                "durationMs": String(finalDurationMs)
            ]
        )
        CrashContextRecorder.shared.record("restore_success op=\(op) outcome=restored durationMs=\(finalDurationMs)")
    }
}
