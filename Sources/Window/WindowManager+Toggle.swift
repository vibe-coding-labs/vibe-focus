import AppKit
import Foundation

// MARK: - Toggle 主编排层
// 文件分层（2026-08-31 拆分；B191 线程重构）：
//   +Toggle.swift（本文件）      — toggle 入口编排（async：主线程快前后置 + 重核心下放
//                                 WindowWorkExecutor）+ performToggleCore 执行体
//   +Toggle+FocusResolution.swift — CGWindowList→yabai→AX 三级焦点窗口解析 + frame 解析纯函数
//   +Toggle+Routes.swift         — moveStuckWindowToSecondaryScreen / moveToMainScreen 路径实现
//   +Toggle+Decision.swift       — RestoreDecision 决策（decideRestore / shouldRestoreCurrentWindow）
//   +Restore.swift               — restore 路径实现
//
// B191 线程模型（装机 34 条 STALL 取证后，B180 hook 路径同款方案补齐手动路径）：
// 主线程只保留 overlay 挂起/恢复与前台读取（<5ms）；重核心（快照+三级焦点解析+
// 决策+三路分发，实测 0.3~1.4s）在 WindowWorkExecutor 串行队列执行，await 期间
// 主线程解放——⌃Q 期间气泡打字/菜单/整个 app 不再冻结。四个子 extension
// （FocusResolution/Decision/Routes/Restore）随之 @MainActor 摘除（体内只有
// AX/CG/yabai/SQLite/NSWorkspace 读，无 NSApp/NSWindow——B180 编译探针结论）。

@MainActor
extension WindowManager {

    /// Core toggle operation: move focused window between main and secondary screens.
    ///
    /// ## 场景
    /// - 触发源：热键（HotKeyManager）、菜单栏；B191 起为 async。
    /// - 路由规则：副屏 → move_to_main（最大化）；有有效 toggle record → restore 回原位；
    ///   主屏且无 record → stuck 解堵（移副屏）。
    ///
    /// ## 并发/竞态约束（必读）
    /// - **overlay 刷新抑制**：restore/move 内部的 yabai `window --space` 会触发
    ///   space_changed signal → SIGUSR1 → force refresh 风暴（多屏 3 次 × 每 screen 2 fork
    ///   = 大量主线程阻塞，是"主屏退回副屏"卡顿的主因）。入口 suspend，defer 中 resume +
    ///   debounce 补刷新——defer 保证无论 toggle 如何退出（含提前 return）都恢复。
    ///   suspend/resume 属 ScreenOverlayManager（@MainActor），保持在主线程调用。
    /// - **焦点解析必须实时**：入口解析的 windowID/identity 贯穿整个 toggle 传递
    ///   （+Toggle+FocusResolution 的三分支），禁止中途重新解析焦点（副屏 AX 阻塞 1.5s+
    ///   且焦点可能已变化）。B191 核心在执行队列开拍即跑（队列空闲毫秒级启动）；
    ///   队列被长 hook 作业占住时解析延迟，以执行时实际窗态为准 + 诚实日志兜底
    ///   （hook 移动完成后聚焦的正是目标终端窗，解析结果通常仍是用户面前那扇窗）。
    ///
    /// ## 样例（耗时归因日志）
    /// `durationMs ≈ snapshotMs + ctxMs + decisionMs + coreOpMs`；ctx 主导耗时看
    /// `focusedBranchMs`（cgwindowlist ~5ms / yabai ~635ms / ax ~1500ms）。
    ///
    /// - Parameters:
    ///   - operationID: Unique identifier for this operation (auto-generated if nil)
    ///   - triggerSource: Origin of the toggle (hotkey, hook, etc.)
    func toggle(operationID: String? = nil, triggerSource: String = "unknown") async {
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
        // 崩溃快照保持主线程（updateCrashSnapshotFromRuntime/logRuntimeStateSnapshot 是
        // @MainActor 全局函数，读 NSWorkspace/NSScreen/HotKeyManager 状态——耗时 ~1ms，
        // B191 前后都在主线程，语义不变）；snapshotMs 传给核心进汇总日志。
        let snapshotStart = Date()
        updateCrashSnapshotFromRuntime()
        logRuntimeStateSnapshot(context: "toggle_start")
        let snapshotMs = elapsedMilliseconds(since: snapshotStart)
        // B191：toggle 区间栈随核心落在 executor 线程（journal 只记主线程区间开始），
        // 手动补一条主线程时间线标记——停顿回放仍能看到「用户按了 ⌃Q」。
        PerfMonitor.shared.journal("▶toggle dispatch op=\(op)")

        // B191：重核心下放窗口作业串行队列（await 期间主线程零占用）。返回后
        // 自动跳回主线程做收尾（frontAfter 读取 + 汇总日志）。
        let core = await WindowWorkExecutor.run {
            self.performToggleCore(
                operationID: op, triggerSource: triggerSource,
                frontBefore: frontBefore, snapshotMs: snapshotMs)
        }

        let frontAfter = frontmostAppDescriptor()
        let durationMs = logOperationDuration(
            "[WindowManager] toggle finished",
            startedAt: startedAt,
            operationID: op,
            warnThresholdMs: 650,
            fields: core.finishedFields(frontAfter: frontAfter)
        )
        if frontBefore != frontAfter {
            log(
                "[WindowManager] frontmost app changed during toggle",
                level: .warn,
                fields: core.frontmostChangeFields(frontAfter: frontAfter)
            )
        }
        if durationMs >= 650 {
            CrashContextRecorder.shared.record("toggle_slow op=\(op) durationMs=\(durationMs) mode=\(core.mode)")
        }
    }
}

// MARK: - 重核心执行体（B191 下放 WindowWorkExecutor；nonisolated，禁碰主线程专属 API）

/// toggle 核心段结果（主线程收尾日志所需字段；Sendable 值类型跨队列传递）。
struct ToggleCoreOutcome: Sendable {
    let mode: String
    let coreOpMs: Int
    let context: [String: String]

    /// 「toggle finished」汇总日志字段（context 全量 + frontAfter + coreOpMs）。
    func finishedFields(frontAfter: String) -> [String: String] {
        var fields = context
        fields["frontAfter"] = frontAfter
        fields["coreOpMs"] = String(coreOpMs)
        return fields
    }

    /// 前台 app 变化告警字段（op/source/mode/frontBefore/frontAfter）。
    func frontmostChangeFields(frontAfter: String) -> [String: String] {
        return [
            "op": context["op"] ?? "nil",
            "source": context["source"] ?? "nil",
            "mode": mode,
            "frontBefore": context["frontBefore"] ?? "nil",
            "frontAfter": frontAfter
        ]
    }
}

extension WindowManager {

    /// toggle 重核心（B191 自 toggle() 逐行提取保移）：三级焦点解析 +
    /// 恢复决策 + 三路分发。在 WindowWorkExecutor 串行队列上执行；禁碰主线程专属
    /// API（NSApp/NSWindow/ScreenOverlayManager/崩溃快照全局函数）——AX/CG/yabai/
    /// SQLite/NSWorkspace 读均非主线程专属（B180 编译探针 + hook 路径真机长期验证）。
    /// E2E（RunnerSizeE2ETests）直接调本函数同步驱动，绕过 actor 调度。
    nonisolated func performToggleCore(
        operationID op: String, triggerSource: String,
        frontBefore: String, snapshotMs: Int
    ) -> ToggleCoreOutcome {
        // B178 常开埋点：⌃Q toggle 热路径区间（随执行线程落 executor，
        // 看门狗跨线程收集——停顿归因不丢）。
        PerfMonitor.shared.beginSection("toggle", fields: ["op": op])
        defer { PerfMonitor.shared.endSection() }

        var toggleContext: [String: String] = [
            "op": op,
            "source": triggerSource,
            "frontBefore": frontBefore,
            "snapshotMs": String(snapshotMs)
        ]

        // 采集当前窗口上下文。
        // 优化：frame 用 CGWindowList（非 AX）替代 AX frame(of:) —— 窗口位于副屏 Space 时
        // AX kAXFrameAttribute 被 WindowServer 阻塞 1500-1900ms（move_to_main ctxMs 主因，
        // toggle-00000187 ctxMs=1918）。
        // 缓存主屏引用：核心同步执行期间屏幕配置不变，复用避免重复 getMainScreen() 遍历。
        let cachedMainScreen = getMainScreen()
        let ctxStart = Date()
        // 三级焦点窗口解析（CGWindowList→yabai→AX），详见 +Toggle+FocusResolution.swift。
        // P2: yabai query focused window（非 AX）消除了 move_to_main 路径 toggle 入口的
        // focusedWindow(for:) 副屏阻塞 1.5s（toggle-00000541 ctxMs=1501）。
        // B190 子阶段区间：ctxMs 典型 ~600ms（yabai 分支）/最差 1.9s，直方图进快照。
        var resolution = PerfMonitor.shared.measure("toggle.ctx") {
            resolveFocusedWindowForToggle(
                frontApp: NSWorkspace.shared.frontmostApplication,
                cachedMainScreen: cachedMainScreen,
                toggleContext: &toggleContext
            )
        }
        // 无窗口前台兜底：SystemUIServer 等系统表面持焦时三级解析必然全空（candidatesCount==0），
        // 直接路由只会死在 "focused window identity missing"（2026-09-06 toggle-00000182 真机实证，
        // 用户视角 = ⌃Q 死键）。改取 z-order 最前普通窗口继续正常决策。
        // 仅限 candidatesCount==0（前台无窗口）；正常 app 解析失败不走此路（z-order≠AX focus，会翻错窗口）。
        if resolution.identity == nil, toggleContext["candidatesCount"] == "0",
           let fallback = resolveFallbackWindowForToggle(
            cachedMainScreen: cachedMainScreen,
            toggleContext: &toggleContext
           ) {
            resolution = fallback
        }
        let resolvedWindowID: UInt32? = resolution.windowID
        let resolvedWindowAX: AXUIElement? = resolution.windowAX
        let resolvedIdentity: WindowIdentity? = resolution.identity
        toggleContext["ctxMs"] = String(elapsedMilliseconds(since: ctxStart))
        log(
            "[WindowManager] toggle started",
            fields: toggleContext
        )

        // 传入入口已解析的 windowID，跳过决策内部重复的
        // focusedWindow/windowHandle AX 查询（副屏 space 阻塞 1-2s，gap2 同源）。
        // P-INST-2: 记录 decisionMs（ctx 与 coreOp 之间的 gap2 来源）。
        // 决策内部走 CGWindowList(isWindowOnMainScreen) + SQLite(load)，应 <5ms；
        // 若 decisionMs 高，说明 AX fallback 路径未跳过或有 SQLite 阻塞。
        let decisionStart = Date()
        let decision = PerfMonitor.shared.measure("toggle.decision") {
            evaluateRestoreDecision(windowID: resolvedWindowID, store: ToggleEngine.shared)
        }
        let decisionMs = elapsedMilliseconds(since: decisionStart)
        // Batch 5：mode 字符串与执行分支同源（route 唯一映射）——此前 mode 计算
        // 与执行 switch 是两份表示，(decision=.moveToMain, onMain=true) 组合下
        // 日志与执行各说各话（stuck 分支记 "move_to_main" 的日志失真）。
        let route = Self.route(for: decision, onMainScreen: resolution.onMainScreen)
        let mode = route.logName

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
                decisionFields["toggleRecordOrigFrame"] = QuartzRect(record.origFrame).description
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
        // 路由 = route 唯一映射（见上方 route 注释与 ToggleRouteTests 分支穷尽锁定）。
        let coreOpStart = Date()
        switch route {
        case .restore:
            restore(operationID: op, triggerSource: triggerSource, windowID: resolvedWindowID)
            // 设置冷却期：防止 Stop 事件立即把刚恢复的窗口再次拉到主屏
            if let winID = resolvedWindowID {
                MoveCooldownRegistry.shared.setCooldown(windowID: winID)
                AuditLogger.shared.record(
                    eventType: "toggle_restore",
                    windowID: winID,
                    details: ["mode": "restore", "source": triggerSource]
                )
            }
        case .moveSecondaryStuck:
            // Window is on main screen but has no valid toggle record → stuck state.
            // Move to secondary screen to unblock the toggle cycle.
            log(
                "[WindowManager] toggle: window stuck on main screen with no toggle record, moving to secondary",
                level: .info,
                fields: ["op": op, "windowID": toggleContext["windowID"] ?? "nil"]
            )
            moveStuckWindowToSecondaryScreen(operationID: op, triggerSource: triggerSource, windowID: resolvedWindowID)
            if let winID = resolvedWindowID {
                AuditLogger.shared.record(
                    eventType: "toggle_move_to_secondary",
                    windowID: winID,
                    details: ["mode": "move_to_secondary_stuck", "source": triggerSource]
                )
            }
        case .moveToMain:
            moveToMainScreen(
                operationID: op,
                triggerSource: triggerSource,
                knownIdentity: resolvedIdentity,
                knownWindowAX: resolvedWindowAX,
                knownOrigFrame: resolution.windowFrame
            )
            if let winID = resolvedWindowID {
                AuditLogger.shared.record(
                    eventType: "toggle_move_to_main",
                    windowID: winID,
                    details: ["mode": "move_to_main", "source": triggerSource]
                )
            }
        }
        let coreOpMs = elapsedMilliseconds(since: coreOpStart)
        return ToggleCoreOutcome(mode: mode, coreOpMs: coreOpMs, context: toggleContext)
    }
}
