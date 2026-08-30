import AppKit
import Foundation

// MARK: - Toggle 主编排层
// 文件分层（2026-08-31 拆分，行为不变）：
//   +Toggle.swift（本文件）      — toggle 入口编排：suspend/resume overlay、解析焦点窗口、
//                                 三路分发（restore / stuck / move_to_main）、耗时归因日志
//   +Toggle+FocusResolution.swift — CGWindowList→yabai→AX 三级焦点窗口解析 + frame 解析纯函数
//   +Toggle+Routes.swift         — moveStuckWindowToSecondaryScreen / moveToMainScreen 路径实现
//   +Toggle+Decision.swift       — RestoreDecision 决策（decideRestore / shouldRestoreCurrentWindow）
//   +Restore.swift               — restore 路径实现

@MainActor
extension WindowManager {

    /// Core toggle operation: move focused window between main and secondary screens.
    ///
    /// ## 场景
    /// - 触发源：热键（HotKeyManager）、菜单栏、hook 请求；每次调用在主线程同步完成。
    /// - 路由规则：副屏 → move_to_main（最大化）；有有效 toggle record → restore 回原位；
    ///   主屏且无 record → stuck 解堵（移副屏）。
    ///
    /// ## 并发/竞态约束（必读）
    /// - **overlay 刷新抑制**：restore/move 内部的 yabai `window --space` 会触发
    ///   space_changed signal → SIGUSR1 → force refresh 风暴（多屏 3 次 × 每 screen 2 fork
    ///   = 大量主线程阻塞，是"主屏退回副屏"卡顿的主因）。入口 suspend，defer 中 resume +
    ///   debounce 补刷新——defer 保证无论 toggle 如何退出（含提前 return）都恢复。
    /// - **焦点解析必须实时**：入口解析的 windowID/identity 贯穿整个 toggle 传递
    ///   （+Toggle+FocusResolution 的三分支），禁止中途重新解析焦点（副屏 AX 阻塞 1.5s+
    ///   且焦点可能已变化）。
    ///
    /// ## 样例（耗时归因日志）
    /// `durationMs ≈ snapshotMs + ctxMs + decisionMs + coreOpMs`；ctx 主导耗时看
    /// `focusedBranchMs`（cgwindowlist ~5ms / yabai ~635ms / ax ~1500ms）。
    ///
    /// - Parameters:
    ///   - operationID: Unique identifier for this operation (auto-generated if nil)
    ///   - triggerSource: Origin of the toggle (hotkey, hook, etc.)
    func toggle(operationID: String? = nil, triggerSource: String = "unknown") {
        let op = operationID ?? makeOperationID(prefix: "toggle")
        let startedAt = Date()
        ScreenOverlayManager.shared.suspendAutomaticRefreshes(reason: "toggle_in_progress op=\(op)")
        defer {
            // P-INST-9: defer 开销（resume + schedulePostToggleRefresh）。不计入 durationMs（在 defer 前计算），
            // 但影响 toggle 真实总开销；通常 <5ms，若高说明 startRefreshTimer/scheduleDispatch 有阻塞。
            let deferStart = Date()
            ScreenOverlayManager.shared.resumeAutomaticRefreshes(reason: "toggle_complete op=\(op)")
            // P3.6: 补一次 force refresh 改 debounce（schedulePostToggleRefresh），替代被抑制的 SIGUSR1。
            // toggle 的 window --space(focus=false) 不改可见 space，overlay 编号不变；连续 toggle 时
            // 立即 force refresh 会堆积后台 yabai query，占用单进程 yabai，让下次 toggle 的同步
            // captureSpaceContext/visibleSpaceIndex fork 排队（前置 query 650ms）。debounce 300ms 释放
            // yabai 给 toggle 热路径，仅在用户停止 toggle 后刷新一次 overlay。
            ScreenOverlayManager.shared.schedulePostToggleRefresh(reason: "toggle_complete op=\(op)")
            log("[WindowManager] toggle defer overhead", fields: [
                "op": op, "deferMs": String(elapsedMilliseconds(since: deferStart))
            ])
        }
        let frontBefore = frontmostAppDescriptor()
        let snapshotStart = Date()
        updateCrashSnapshotFromRuntime()
        logRuntimeStateSnapshot(context: "toggle_start")
        let snapshotMs = elapsedMilliseconds(since: snapshotStart)

        // 采集当前窗口上下文。
        // 优化：frame 用 CGWindowList（非 AX）替代 AX frame(of:) —— 窗口位于副屏 Space 时
        // AX kAXFrameAttribute 被 WindowServer 阻塞 1500-1900ms（move_to_main ctxMs 主因，
        // toggle-00000187 ctxMs=1918）。
        // 缓存主屏引用：toggle 同步执行期间屏幕配置不变，复用避免重复 getMainScreen() 遍历。
        let cachedMainScreen = getMainScreen()
        let ctxStart = Date()
        var toggleContext: [String: String] = [
            "op": op,
            "source": triggerSource,
            "frontBefore": frontBefore,
            "snapshotMs": String(snapshotMs)
        ]
        // 三级焦点窗口解析（CGWindowList→yabai→AX），详见 +Toggle+FocusResolution.swift。
        // P2: yabai query focused window（非 AX）消除了 move_to_main 路径 toggle 入口的
        // focusedWindow(for:) 副屏阻塞 1.5s（toggle-00000541 ctxMs=1501）。
        let resolution = resolveFocusedWindowForToggle(
            frontApp: NSWorkspace.shared.frontmostApplication,
            cachedMainScreen: cachedMainScreen,
            toggleContext: &toggleContext
        )
        let resolvedWindowID: UInt32? = resolution.windowID
        let resolvedWindowAX: AXUIElement? = resolution.windowAX
        let resolvedIdentity: WindowIdentity? = resolution.identity
        toggleContext["ctxMs"] = String(elapsedMilliseconds(since: ctxStart))
        log(
            "[WindowManager] toggle started",
            fields: toggleContext
        )

        // 传入入口已解析的 windowID，跳过 shouldRestoreCurrentWindow 内部重复的
        // focusedWindow/windowHandle AX 查询（副屏 space 阻塞 1-2s，gap2 同源）。
        // P-INST-2: 记录 decisionMs（ctx 与 coreOp 之间的 gap2 来源）。
        // shouldRestore 内部走 CGWindowList(isWindowOnMainScreen) + SQLite(load)，应 <5ms；
        // 若 decisionMs 高，说明 AX fallback 路径未跳过或有 SQLite 阻塞。
        let decisionStart = Date()
        let shouldRestore = shouldRestoreCurrentWindow(windowID: resolvedWindowID, store: ToggleEngine.shared)
        let decisionMs = elapsedMilliseconds(since: decisionStart)
        let mode = shouldRestore ? "restore" : "move_to_main"

        // 采集 toggle record 状态用于决策日志
        var decisionFields: [String: String] = [
            "op": op,
            "source": triggerSource,
            "mode": mode,
            "decisionMs": String(decisionMs),
            "windowFrame": toggleContext["windowFrame"] ?? "nil",
            "onMainScreen": toggleContext["onMainScreen"] ?? "nil",
            "windowID": toggleContext["windowID"] ?? "nil"
        ]
        if let winID = resolvedWindowID {
            if let record = ToggleEngine.shared.load(windowID: winID) {
                decisionFields["toggleRecordExists"] = "true"
                decisionFields["toggleRecordOrigFrame"] = "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y)) \(Int(record.origFrame.size.width))x\(Int(record.origFrame.size.height))"
                decisionFields["toggleRecordSourceSpace"] = String(record.sourceSpace)
                if let mainScreen = cachedMainScreen {
                    decisionFields["toggleRecordValid"] = String(record.isValid(mainScreenFrame: mainScreen.frame))
                }
            } else {
                decisionFields["toggleRecordExists"] = "false"
            }
        }
        log(
            "[WindowManager] toggle decision",
            fields: decisionFields
        )

        // coreOpMs：核心操作（restore / moveToMain / moveStuck）净耗时，与 snapshotMs/ctxMs（决策前置）区分。
        let coreOpStart = Date()
        if shouldRestore {
            restore(operationID: op, triggerSource: triggerSource)
            // 设置冷却期：防止 Stop 事件立即把刚恢复的窗口再次拉到主屏
            if let winID = resolvedWindowID {
                HookEventHandler.shared.setMoveCooldown(windowID: winID)
                AuditLogger.shared.record(
                    eventType: "toggle_restore",
                    windowID: winID,
                    details: ["mode": "restore", "source": triggerSource]
                )
            }
        } else if toggleContext["onMainScreen"] == "true" {
            // Window is on main screen but has no valid toggle record → stuck state.
            // Move to secondary screen to unblock the toggle cycle.
            log(
                "[WindowManager] toggle: window stuck on main screen with no toggle record, moving to secondary",
                level: .info,
                fields: ["op": op, "windowID": toggleContext["windowID"] ?? "nil"]
            )
            moveStuckWindowToSecondaryScreen(operationID: op, triggerSource: triggerSource)
            if let winID = resolvedWindowID {
                AuditLogger.shared.record(
                    eventType: "toggle_move_to_secondary",
                    windowID: winID,
                    details: ["mode": "move_to_secondary_stuck", "source": triggerSource]
                )
            }
        } else {
            let knownOrigFrame = toggleContext["windowFrame"].flatMap { frameStr in
                // Parse "CGRect(x, y, w, h)" format from toggleContext
                // This is the frame captured by CGWindowList BEFORE any yabai space move
                parseFrameString(frameStr)
            }
            moveToMainScreen(operationID: op, triggerSource: triggerSource, knownIdentity: resolvedIdentity, knownWindowAX: resolvedWindowAX, knownOrigFrame: knownOrigFrame)
            if let winID = resolvedWindowID {
                AuditLogger.shared.record(
                    eventType: "toggle_move_to_main",
                    windowID: winID,
                    details: ["mode": "move_to_main", "source": triggerSource]
                )
            }
        }
        let coreOpMs = elapsedMilliseconds(since: coreOpStart)

        let frontAfter = frontmostAppDescriptor()
        let durationMs = logOperationDuration(
            "[WindowManager] toggle finished",
            startedAt: startedAt,
            operationID: op,
            warnThresholdMs: 650,
            fields: [
                "source": triggerSource,
                "mode": mode,
                "frontBefore": frontBefore,
                "frontAfter": frontAfter,
                "coreOpMs": String(coreOpMs),
                // P-INST-8: 汇总关键决策字段到 finished 一行，方便单行瓶颈归因
                // （durationMs ≈ snapshotMs + ctxMs + decisionMs + coreOpMs；deferMs 见单独 defer 日志）。
                "ctxMs": toggleContext["ctxMs"] ?? "nil",
                "focusedWindowSource": toggleContext["focusedWindowSource"] ?? "nil",
                "focusedBranchMs": toggleContext["focusedBranchMs"] ?? "nil",
                "candidatesCount": toggleContext["candidatesCount"] ?? "nil",
                "decisionMs": String(decisionMs)
            ]
        )
        if frontBefore != frontAfter {
            log(
                "[WindowManager] frontmost app changed during toggle",
                level: .warn,
                fields: [
                    "op": op,
                    "source": triggerSource,
                    "mode": mode,
                    "frontBefore": frontBefore,
                    "frontAfter": frontAfter
                ]
            )
        }
        if durationMs >= 650 {
            CrashContextRecorder.shared.record("toggle_slow op=\(op) durationMs=\(durationMs) mode=\(mode)")
        }
    }
}
