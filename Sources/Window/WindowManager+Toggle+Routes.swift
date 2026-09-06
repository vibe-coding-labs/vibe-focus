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
    /// - 仅 `toggle(operationID:triggerSource:)` 的 stuck 分支调用；
    /// - windowID 传 toggle 入口已解析的 resolution.windowID（此前自行 AX 重解析，
    ///   是 toggle 内重复焦点解析的已知优化点，2026-09-01 迁移；nil 时保留 AX 兜底）。
    ///
    /// ## 移动机制（2026-09-01 从 `window --space` 迁移）
    /// 原 yabai `window --space` 在 v7 float 布局下静默失效（exit 0 但窗口不动，
    /// Tests/AXMoveValidation.swift T3 断言实测），stuck 解堵全部落空且无感知。
    /// 现改用与 restore/move_to_main 相同的已验证路径：float 脱管 → settle 等 yabai
    /// 默认重摆 → `--move abs`/`--resize abs` 直写副屏 visibleFrame（窗口归属跟随
    /// 物理位置切 display），moveWindowToFrameViaYabai 内置写后读回闭环验证。
    ///
    /// ## 竞态/历史 bug（必读）
    /// 原实现曾把 NSScreen screenArrayIndex（0-based）当 yabai display index（1-based）
    /// 用，副屏被当成主屏导致 stuck 死循环（toggle-00000138）。现目标屏只用于取
    /// frame，索引换算集中在 CoordinateKit.nsScreen(forYabaiDisplayIndex:)。
    func moveStuckWindowToSecondaryScreen(operationID: String, triggerSource: String, windowID knownWindowID: UInt32? = nil) {
        // P-INST-10: stuck 路径总耗时（defer 汇总，所有 return 路径）+ AX lookup 耗时。
        #if PERF_INSTRUMENT
        let stuckStart = Date()
        defer {
            log("[WindowManager] moveStuckWindowToSecondaryScreen finished", fields: [
                "op": operationID, "stuckMs": String(elapsedMilliseconds(since: stuckStart))
            ])
        }
        #endif
        let axLookupStart = Date()
        let axResolvedID: UInt32? = knownWindowID ?? NSWorkspace.shared.frontmostApplication
            .flatMap { focusedWindow(for: $0.processIdentifier) }
            .flatMap { windowHandle(for: $0) }
        let axLookupMs = elapsedMilliseconds(since: axLookupStart)
        guard let windowID = axResolvedID else {
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

        // 目标屏：与当前 display 不同且有可见 space 的 display → NSScreen；
        // yabai display 映射不到 NSScreen 时回退第一个非主屏。
        let currentDisplay = windowInfo?.display
        let targetYabaiDisplay = spaces?.first(where: { $0.display != currentDisplay && $0.isVisible == true })?.display
        let targetScreen = targetYabaiDisplay.flatMap { CoordinateKit.nsScreen(forYabaiDisplayIndex: $0) }
            ?? NSScreen.screens.first(where: { $0.frame.origin != .zero })
        guard let targetScreen else {
            log("[WindowManager] moveStuckWindowToSecondaryScreen: no secondary screen", level: .warn, fields: [
                "op": operationID, "windowID": String(windowID)
            ])
            return
        }

        // float 脱管 + settle（等 yabai 默认重摆落定）→ frame 直写（闭环验证内置）。
        // 已 float 零等待（skippedNoOp 无重摆）；真 toggle 时等稳定代等固定
        // （waitForRelayout，同 move_to_main P2 注释）。
        let moveStart = Date()
        var stuckFloatToggled = false
        if let info = windowInfo, !info.isFloating {
            let floatOutcome = spaceController.setWindowFloat(windowID, operationID: operationID, knownWindowInfo: info)
            stuckFloatToggled = floatOutcome.didToggle
        }
        if stuckFloatToggled {
            FrameConvergence.waitForRelayout(
                minSettleMicros: WindowSettle.floatRelayoutMinSettleMicros,
                intervalMs: WindowSettle.frameVerifyPollIntervalMs,
                budgetMs: WindowSettle.floatRelayoutSettleMicros,
                read: { cgWindowBounds(for: windowID) },
                isSame: { CoordinateKit.isFrameConverged(actual: $1, target: $0, tolerance: frameTolerance) }
            )
        }
        spaceController.clearWindowQueryCache()
        // 2026-09-06 尺寸保真修复：解堵 = 把卡住的窗口挪去副屏，**保持窗口当前尺寸**
        // （位置放副屏可视区原点、整框向内夹紧；窗口大于副屏可视区时才收窄）。
        // 旧实现目标 = 副屏整屏可视区（3440x1440），任何窗口一解堵就被放大成
        // 整屏——用户主诉「移动窗口连尺寸都搞错了」的直接来源（观测堆栈+E2E 复现：
        // 系统设置抢焦点后 toggle 误入 stuck 路由，普通窗口被撑满整副屏）。
        let secondaryVisible = CoordinateKit.quartzVisibleFrame(of: targetScreen)
        let currentBounds = cgWindowBounds(for: windowID) ?? secondaryVisible
        let keptWidth = min(currentBounds.width, secondaryVisible.width)
        let keptHeight = min(currentBounds.height, secondaryVisible.height)
        let keptX = max(secondaryVisible.minX, min(currentBounds.origin.x, secondaryVisible.maxX - keptWidth))
        let keptY = max(secondaryVisible.minY, min(currentBounds.origin.y, secondaryVisible.maxY - keptHeight))
        let targetFrame = CGRect(x: keptX, y: keptY, width: keptWidth, height: keptHeight)
        let moved = moveWindowToFrameViaYabai(
            windowID: windowID,
            frame: targetFrame,
            op: operationID,
            stage: "move_to_secondary_stuck",
            // 源屏=主屏（stuck 窗口必在主屏）；尺寸保持后目标 ≤ 当前尺寸（缩小序），
            // 此参数仅供判定兜底 + 缩小序源屏先行判定。
            sourceVisibleFrame: CoordinateKit.quartzVisibleFrame(of: getMainScreen() ?? targetScreen)
        )
        let moveMs = elapsedMilliseconds(since: moveStart)
        log(
            "[WindowManager] moveStuckWindowToSecondaryScreen: frame move",
            level: moved ? .info : .error,
            fields: [
                "op": operationID,
                "windowID": String(windowID),
                "currentDisplay": String(currentDisplay ?? 0),
                "targetScreen": String(describing: targetScreen.localizedName),
                "targetFrame": QuartzRect(targetFrame).description,
                "moved": String(moved),
                "queryMs": String(queryMs),
                "moveMs": String(moveMs)
            ]
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
        MoveCooldownRegistry.shared.clearCooldown(windowID: identity.windowID)
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
