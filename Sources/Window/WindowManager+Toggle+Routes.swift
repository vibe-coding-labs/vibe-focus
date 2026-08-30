import AppKit
import Foundation

// MARK: - Toggle 路径实现层
// toggle 决策（+Toggle.swift）落到两个具体动作：卡死窗口解堵（副屏）与移主屏最大化。
// restore 路径实现在 +Restore.swift，决策逻辑在 +Toggle+Decision.swift。

@MainActor
extension WindowManager {

    /// 卡死解堵：窗口在主屏但没有有效 toggle record（上一轮 restore 已消费）时，
    /// 把它移到副屏，让 toggle 循环恢复"主↔副"交替。
    ///
    /// ## 场景
    /// - 仅 `toggle(operationID:triggerSource:)` 的 stuck 分支调用（shouldRestore == false
    ///   且 onMainScreen == true）；
    /// - 本方法自行解析焦点窗口（toggle 入口的解析结果未传入——历史行为，P-INST-10 埋点
    ///   暴露的重复 AX 查询优化点，改动需连同 toggle 入口一起评估）。
    ///
    /// ## 竞态/历史 bug（必读）
    /// 原 displayIndex(forDisplayID:) 返回 NSScreen screenArrayIndex（0-based），但
    /// displayVisibleSpace(.yabai(...)) 期望 yabai display index（1-based）：副屏
    /// screenArrayIndex=1 被当成 yabai display 1（主屏），window --space <主屏 space> 把
    /// 卡住的窗口又移回主屏，toggle 进入 stuck 死循环（toggle-00000138：moved=true 但窗口
    /// 停留主屏）。现改用 queryWindow 拿窗口当前 yabai display，从 querySpaces 找
    /// display != currentDisplay 的 visible space，映射与 yabai 一致。
    func moveStuckWindowToSecondaryScreen(operationID: String, triggerSource: String) {
        // P-INST-10: stuck 路径总耗时（defer 汇总，所有 return 路径）+ AX lookup 耗时。
        let stuckStart = Date()
        defer {
            log("[WindowManager] moveStuckWindowToSecondaryScreen finished", fields: [
                "op": operationID, "stuckMs": String(elapsedMilliseconds(since: stuckStart))
            ])
        }
        let axLookupStart = Date()
        let windowID = NSWorkspace.shared.frontmostApplication
            .flatMap { focusedWindow(for: $0.processIdentifier) }
            .flatMap { windowHandle(for: $0) }
        let axLookupMs = elapsedMilliseconds(since: axLookupStart)
        guard let windowID = windowID else {
            log("[WindowManager] moveStuckWindowToSecondaryScreen: no focused window", level: .warn, fields: [
                "op": operationID, "axLookupMs": String(axLookupMs)
            ])
            return
        }

        let spaceController = SpaceController.shared

        let queryStart = Date()
        let windowInfo = spaceController.queryWindow(windowID: windowID)
        let spaces = spaceController.querySpaces()
        let queryMs = elapsedMilliseconds(since: queryStart)
        if let currentDisplay = windowInfo?.display,
           let targetSpace = spaces?.first(where: {
               $0.display != currentDisplay && $0.isVisible == true
           })?.index.map({ SpaceIdentifier.yabai($0) }) {
            let moveStart = Date()
            let moved = spaceController.moveWindow(
                windowID,
                toSpace: targetSpace,
                focus: false,
                operationID: operationID
            )
            let moveMs = elapsedMilliseconds(since: moveStart)
            log(
                "[WindowManager] moveStuckWindowToSecondaryScreen: yabai space move",
                fields: [
                    "op": operationID,
                    "windowID": String(windowID),
                    "currentDisplay": String(currentDisplay),
                    "targetSpace": String(describing: targetSpace),
                    "moved": String(moved),
                    "queryMs": String(queryMs),
                    "moveMs": String(moveMs)
                ]
            )
            if moved { return }
        }

        log(
            "[WindowManager] moveStuckWindowToSecondaryScreen: yabai space move failed, no fallback",
            level: .warn,
            fields: ["op": operationID, "windowID": String(windowID)]
        )
    }

    /// Move the currently focused window to the main screen maximized.
    ///
    /// This is the "move to main" half of the toggle operation. The window is:
    /// 1. Moved to the main screen's visible space (via yabai or AX)
    /// 2. Set to floating (detached from yabai tiling)
    /// 3. Resized to fill the main screen
    /// 4. A toggle record is saved for future restore
    ///
    /// ## 场景
    /// - toggle 的 move_to_main 分支调用（传入入口预解析的 identity/AX/frame）；
    /// - 也是公开入口（默认参数完整），可独立于 toggle 使用。
    ///
    /// ## 竞态/历史 bug
    /// - knownOrigFrame 必须是 yabai space move **之前**的 frame 快照：move 之后 AX frame
    ///   已变成主屏新值，用它当还原基准会把"最大化后的 frame"记成原始位置（a049a86
    ///   副屏单窗口 toggle 后尺寸缩小的同源问题）。
    /// - focus 用 Carbon AX（raise + kAXFocused）而非 yabai window --focus：后者会切到
    ///   窗口的 yabai space 触发动画（实测 306ms，toggle-00000310）。
    ///
    /// - Parameters:
    ///   - operationID: Unique identifier (auto-generated if nil)
    ///   - triggerSource: Origin of the move (hotkey, hook, etc.)
    ///   - knownIdentity: Pre-resolved window identity (avoids redundant AX queries)
    ///   - knownWindowAX: Pre-resolved AXUIElement (avoids redundant AX queries)
    ///   - knownOrigFrame: Pre-captured original frame (avoids reading post-space-move frame)
    func moveToMainScreen(operationID: String? = nil, triggerSource: String = "unknown", knownIdentity: WindowIdentity? = nil, knownWindowAX: AXUIElement? = nil, knownOrigFrame: CGRect? = nil) {
        let op = operationID ?? makeOperationID(prefix: "move")
        let startedAt = Date()
        log(
            "[WindowManager] move_to_main started",
            fields: [
                "op": op,
                "source": triggerSource
            ]
        )

        let axTrusted = hasAccessibilityPermission()

        if !axTrusted {
            log(
                "[WindowManager] move_to_main failed: accessibility denied",
                level: .warn,
                fields: [
                    "op": op
                ]
            )
            CrashContextRecorder.shared.record("move_to_main_ax_denied op=\(op)")
            logDiagnostics("ax_trusted_false_move")
            notifyAccessibilityPermissionRequired()
            return
        }
        // 复用 toggle 入口已解析的 identity（knownIdentity），省 captureFocusedWindowIdentity 的 4 个 AX
        // 调用（focusedWindow + windowHandle + windowNumber + title），副屏窗口时全阻塞。
        guard let identity = knownIdentity ?? captureFocusedWindowIdentity() else {
            log(
                "[WindowManager] move_to_main failed: focused window identity missing",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            CrashContextRecorder.shared.record("move_to_main_failed_identity_missing op=\(op)")
            return
        }
        let moved = moveWindowToMainScreen(
            identity: identity,
            reason: .manualHotkey,
            sessionID: nil,
            operationID: op,
            knownWindowAX: knownWindowAX,
            knownOrigFrame: knownOrigFrame
        )
        HookEventHandler.shared.clearAutoRestoreCooldown(windowID: identity.windowID)
        if moved {
            // P-INST-4: focusMs 诊断 move_to_main 结尾的 AX raise+focus 隐藏开销（内部含 findWindowByPID
            // AX 查找 + CGWindowListCopyWindowInfo 全扫，主屏窗口应 <20ms，若高说明跨屏阻塞未消除）。
            let focusStart = Date()
            let focusOK = focusWindowByCGWindowID(identity.windowID)
            let focusMs = elapsedMilliseconds(since: focusStart)
            log(
                "MOVED AND MAXIMIZED ON TARGET SCREEN",
                fields: [
                    "op": op,
                    "durationMs": String(elapsedMilliseconds(since: startedAt)),
                    "focusMs": String(focusMs),
                    "focusOK": String(focusOK)
                ]
            )
        } else {
            log(
                "MOVE FAILED",
                level: .error,
                fields: [
                    "op": op,
                    "durationMs": String(elapsedMilliseconds(since: startedAt))
                ]
            )
            CrashContextRecorder.shared.record("move_to_main_failed op=\(op)")
        }
    }
}
