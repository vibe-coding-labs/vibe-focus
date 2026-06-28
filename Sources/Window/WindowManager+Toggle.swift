import AppKit
import Foundation

@MainActor
extension WindowManager {

    func toggle(operationID: String? = nil, triggerSource: String = "unknown") {
        let op = operationID ?? makeOperationID(prefix: "toggle")
        let startedAt = Date()
        // 暂停 overlay 自动刷新：restore/move 内部的 yabai `window --space` 会触发
        // space_changed signal → SIGUSR1 → force refresh 风暴（多屏 3 次 × 每 screen 2 fork
        // = 大量主线程阻塞，是"主屏退回副屏"卡顿的主因）。toggle 期间抑制，结束后补一次。
        ScreenOverlayManager.shared.suspendAutomaticRefreshes(reason: "toggle_in_progress op=\(op)")
        // defer 保证：无论 toggle 如何退出（含提前 return / 异常），overlay 刷新都会恢复。
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
        // toggle-00000187 ctxMs=1918）。决策由 shouldRestoreCurrentWindow 独立用 CGWindowList
        // 完成，此处的 frame/onMainScreen 仅用于日志，可安全换用 CGWindowList。
        // 保留 focusedWindow/windowHandle/title 每个 AX 调用的计时用于诊断剩余瓶颈。
        // 解析一次 windowID 供后续多处复用（避免重复 String→UInt32 解析）。
        var resolvedWindowID: UInt32?
        // 复用 toggle 入口已解析的 AXUIElement / identity 给 moveToMainScreen，省去
        // captureFocusedWindowIdentity（4 AX）+ resolveWindow（2 AX）的重复查询。副屏窗口时
        // 这些 AX 全被 WindowServer 阻塞（toggle-00000320 focusedWindowAxMs=1510ms 同源）。
        var resolvedWindowAX: AXUIElement?
        var resolvedIdentity: WindowIdentity?
        // 缓存主屏引用：toggle 同步执行期间屏幕配置不变，复用避免重复 getMainScreen() 遍历。
        let cachedMainScreen = getMainScreen()
        let ctxStart = Date()
        var toggleContext: [String: String] = [
            "op": op,
            "source": triggerSource,
            "frontBefore": frontBefore,
            "snapshotMs": String(snapshotMs)
        ]
        // P2: 优先 yabai query focused window（非 AX），消除 move_to_main 路径 toggle 入口的
        // focusedWindow(for:) 副屏阻塞 1.5s（toggle-00000541 ctxMs=1501 focusedWindowAxMs=1501）。
        // yabai `query --windows --window`（无 ID）返回系统焦点窗口，id=CGWindowID 与 AX
        // _AXUIElementGetWindow 一致。pid 校验 yabai 焦点窗口 = frontmostApp（不一致说明 yabai 与
        // 系统焦点不同步，回退 AX）。yabai 路径下 resolvedWindowAX=nil，moveWindowToMainScreen
        // 改用 yabai space move 先行（窗口移到主屏后再 AX resolveWindow，主屏不阻塞）。
        // CGWindowList 无法可靠识别多窗口 app 的 focused 窗口（iTerm2 layer==0 first match 181
        // ≠ AX focused 170，P0.3 回退教训），但 yabai query --window 直接返回系统焦点窗口，可靠。
        let axStart = Date()
        var focusedWindowSource = "ax"
        // P-INST-1: 命中分支净探测耗时（cglist/yabai/ax 三选一），用于定位 ctx 635ms 来自哪个分支。
        // cglist 分支=cgListProbeMs（快照+filter）；yabai 分支=queryFocusedWindow fork；ax 分支=focusedWindow+windowHandle。
        var focusedBranchMs: Int = 0
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let frontPID = frontApp.processIdentifier
            // P3.3: 优先 CGWindowList（非阻塞 ~5ms）拿焦点窗口 windowID/frame/title。
            // yabai queryFocusedWindow 查副屏焦点窗口慢 648ms（toggle-00000242+ seq=246-683，stdout frame
            // y=-707 副屏坐标，WindowServer 跨屏固有），AX focusedWindow(for:) 同场景阻塞 1.5s。CGWindowList
            // 是 WindowServer 快照，非阻塞。可靠性：candidates（ownerPID==frontPID, layer==0, isOnScreen）
            // 恰好 1 个 = 单窗口 app 唯一可见窗口 = 焦点；多窗口（>1）无法从 z-order 定 AX focus
            // （P0.3 回退教训：iTerm2 layer==0 first 181 ≠ AX focused 170），fallback yabai queryFocusedWindow
            // （慢但正确）。move_to_main 窗口副屏 onscreen，candidates 含它，count==1 即焦点。
            // memory feedback_toggle_ctxms_cgwindowlist：热路径读 frame 禁 AX，必须 CGWindowList —— 此处
            // 把同一原则扩展到 windowID 解析（先前仅 frame 用 CGWindowList，windowID 仍走 yabai/AX 副屏慢路径）。
            // P-INST-1: cgwindowlist 快照探测计时 + 候选数。量化 P3.3 命中率
            // （count==1 = 单窗口命中快速路径；count>1 = 多窗口必须 fallback yabai；count==0 = 异常）。
            let cgListProbeStart = Date()
            let cgSnapshot = cgWindowListAll()
            let candidates = cgSnapshot.filter { $0.ownerPID == frontPID && $0.layer == 0 && $0.isOnScreen }
            let cgListProbeMs = elapsedMilliseconds(since: cgListProbeStart)
            toggleContext["cgListProbeMs"] = String(cgListProbeMs)
            toggleContext["candidatesCount"] = String(candidates.count)
            // 多窗口 app 焦点定位：candidates==1（单窗口，CGWindowList 可靠）→ cgwindowlist；
            // 否则必须 yabai queryFocusedWindow（拿系统真实焦点，副屏慢 ~648ms 是 WindowServer 跨 Space
            // 固有，无快速 API 可绕）。曾尝试 P3.4 缓存 lastFocusedWindowID 绕过（ctx 502→25ms），但
            // 用户切换同 app 另一窗口后缓存仍命中 → 永远操作旧窗口（"只能切换固定窗口"功能回归），
            // 已回退。焦点身份必须每次实时查询，不可缓存猜测。memory feedback_toggle_ctxms_cgwindowlist：
            // 热路径读 frame 禁 AX，但 windowID 解析多窗口必须 yabai（CGWindowList z-order ≠ AX focus）。
            if candidates.count == 1, let entry = candidates.first, let bounds = entry.bounds {
                focusedWindowSource = "cgwindowlist"
                focusedBranchMs = cgListProbeMs
                resolvedWindowID = entry.windowID
                resolvedWindowAX = nil  // 延迟 AX：move_to_main 走 yabai space move 先行
                toggleContext["windowID"] = String(entry.windowID)
                toggleContext["windowFrame"] = String(describing: bounds)
                if let mainScreen = cachedMainScreen {
                    let windowCenter = CGPoint(x: bounds.midX, y: bounds.midY)
                    toggleContext["onMainScreen"] = String(mainScreen.frame.contains(windowCenter))
                }
                toggleContext["windowTitle"] = truncateForLog(entry.name ?? "", limit: 60)
                resolvedIdentity = WindowIdentity(
                    windowID: entry.windowID,
                    pid: frontPID,
                    bundleIdentifier: frontApp.bundleIdentifier,
                    appName: frontApp.localizedName,
                    windowNumber: Int(entry.windowID),
                    title: entry.name
                )
            } else {
                // P-INST-1: yabai 分支探测计时（queryFocusedWindow fork，副屏 ~635ms 是 ctx 主因）。
                // 把 else-if 条件里的 queryFocusedWindow() 提前到块开头单独计时，逻辑等价（无副作用差异）。
                let yabaiProbeStart = Date()
                let focusedInfo = spaceController.queryFocusedWindow()
                let yabaiProbeMs = elapsedMilliseconds(since: yabaiProbeStart)
                toggleContext["yabaiProbeMs"] = String(yabaiProbeMs)
                if let focusedInfo = focusedInfo,
                   let yabaiWinID = focusedInfo.id,
                   let winID = UInt32(exactly: yabaiWinID),
                   focusedInfo.pid == Int(frontPID) {
                    // yabai fallback（多窗口 / CGWindowList 候选≠1）：副屏慢 648ms，但可靠拿系统焦点窗口。
                    focusedWindowSource = "yabai"
                    focusedBranchMs = yabaiProbeMs
                    resolvedWindowID = winID
                    resolvedWindowAX = nil
                    toggleContext["windowID"] = String(winID)
                    let bounds = focusedInfo.frame?.cgRect ?? .zero
                    toggleContext["windowFrame"] = String(describing: bounds)
                    if let mainScreen = cachedMainScreen {
                        let windowCenter = CGPoint(x: bounds.midX, y: bounds.midY)
                        toggleContext["onMainScreen"] = String(mainScreen.frame.contains(windowCenter))
                    }
                    toggleContext["windowTitle"] = truncateForLog(focusedInfo.title ?? focusedInfo.app ?? "", limit: 60)
                    resolvedIdentity = WindowIdentity(
                        windowID: winID,
                        pid: frontPID,
                        bundleIdentifier: frontApp.bundleIdentifier,
                        appName: frontApp.localizedName,
                        windowNumber: Int(winID),
                        title: focusedInfo.title ?? focusedInfo.app
                    )
                } else {
                    // P-INST-1: AX 分支探测计时（focusedWindow + windowHandle，副屏阻塞 ~1.5s）。
                    let axProbeStart = Date()
                    let focusedWin = focusedWindow(for: frontPID)
                    let winID = focusedWin.flatMap { windowHandle(for: $0) }
                    let axProbeMs = elapsedMilliseconds(since: axProbeStart)
                    toggleContext["axProbeMs"] = String(axProbeMs)
                    if let focusedWin = focusedWin, let winID = winID {
                        focusedWindowSource = "ax"
                        focusedBranchMs = axProbeMs
                        // AX fallback：yabai 不可用 / query 失败 / pid 不一致时保持原逻辑（副屏阻塞 1.5s）。
                        // 遵循 memory feedback_toggle_ctxms_cgwindowlist：热路径读 frame 禁 AX frame(of:)，
                        // 故 frame/title 仍走 CGWindowList（按已知 windowID 查，非 AX）。
                        resolvedWindowID = winID
                        resolvedWindowAX = focusedWin
                        toggleContext["windowID"] = String(winID)
                        let cgList = cgWindowListAll()
                        if let entry = cgList.first(where: { $0.windowID == winID }) {
                            if let bounds = entry.bounds {
                                toggleContext["windowFrame"] = String(describing: bounds)
                                if let mainScreen = cachedMainScreen {
                                    let windowCenter = CGPoint(x: bounds.midX, y: bounds.midY)
                                    toggleContext["onMainScreen"] = String(mainScreen.frame.contains(windowCenter))
                                }
                            }
                            toggleContext["windowTitle"] = truncateForLog(entry.name ?? "", limit: 60)
                            resolvedIdentity = WindowIdentity(
                                windowID: winID,
                                pid: frontApp.processIdentifier,
                                bundleIdentifier: frontApp.bundleIdentifier,
                                appName: frontApp.localizedName,
                                windowNumber: Int(winID),
                                title: entry.name
                            )
                        }
                    }
                }
            }
        }  // 关闭外层 if let frontApp（P3.3：CGWindowList/yabai/AX 三分支容器）
        let focusedWindowAxMs = elapsedMilliseconds(since: axStart)
        toggleContext["focusedWindowSource"] = focusedWindowSource
        toggleContext["focusedWindowAxMs"] = String(focusedWindowAxMs)
        // P-INST-1: 命中分支净耗时（仅命中分支有值）。与 focusedWindowAxMs（三分支总耗时，含失败探测）对照，
        // 可精确定位 ctx 主导耗时来自 cglist（~5ms）/yabai（~635ms）/ax（~1.5s）哪个分支。
        toggleContext["focusedBranchMs"] = String(focusedBranchMs)
        toggleContext["winIDAxMs"] = "0"  // windowHandle 合并进 axStart 计时（紧随 focusedWindow）
        toggleContext["titleAxMs"] = "0"   // title 改 CGWindowList
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
            moveToMainScreen(operationID: op, triggerSource: triggerSource, knownIdentity: resolvedIdentity, knownWindowAX: resolvedWindowAX)
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

    private func moveStuckWindowToSecondaryScreen(operationID: String, triggerSource: String) {
        // P-INST-10: stuck 路径总耗时（defer 汇总，所有 return 路径）+ AX lookup 耗时。
        // 注意：toggle 入口已用 CGWindowList/yabai 解析 windowID，但 moveStuck 未复用，重复 AX 查询
        // （focusedWindow + windowHandle，副屏可能阻塞）——埋点暴露此优化机会。
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

        // 用 yabai 查询窗口当前 display，再找另一 display（= 副屏）的 visible space。
        // BUG 修复：原 displayIndex(forDisplayID:) 返回的是 NSScreen screenArrayIndex（0-based），
        // 但 displayVisibleSpace(.yabai(...)) 期望 yabai display index（1-based）—— 副屏
        // screenArrayIndex=1 被当成 yabai display 1（主屏），window --space <主屏 space> 把卡住的
        // 窗口移回主屏 space，toggle 进入 stuck 死循环（toggle-00000138：moved=true 但窗口停留主屏）。
        // 改用 queryWindow 拿窗口当前 yabai display（卡在主屏时=主屏 display），从 querySpaces 找
        // display != currentDisplay 的 visible space，映射与 yabai 一致。
        // P-INST-28: queryMs（queryWindow+querySpaces）+ moveMs（moveWindow yabai space move），让 stuckMs 自包含归因。
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

    func moveToMainScreen(operationID: String? = nil, triggerSource: String = "unknown", knownIdentity: WindowIdentity? = nil, knownWindowAX: AXUIElement? = nil) {
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
            knownWindowAX: knownWindowAX
        )
        HookEventHandler.shared.clearAutoRestoreCooldown(windowID: identity.windowID)
        if moved {
            // Carbon AX focus（raise + kAXFocused）替代 yabai window --focus —— 后者会切到窗口的
            // yabai space 触发 space 动画（实测 306ms，toggle-00000310）。move_to_main 后窗口 AX frame
            // 已在主屏坐标，Carbon focus 主屏坐标窗口不切 space（~10ms），用户视角正确留主屏。
            // yabai space 记录窗口仍在副屏，但 AX frame 在主屏，Carbon focus 按坐标窗口正确生效。
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

    // Restore 决策逻辑已移至 WindowManager+Toggle+Decision.swift
    // 包含: RestoreDecision 枚举, decideRestore(), shouldRestoreCurrentWindow()
}
