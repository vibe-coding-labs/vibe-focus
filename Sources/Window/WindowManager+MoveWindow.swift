import SwiftUI
import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - Window Move Operations（主编排）
// 文件分层（2026-08-31 拆分，行为不变）：
//   +MoveWindow.swift（本文件）          — runShellCommand 委托 + moveWindowToMainScreen 编排
//   +MoveWindow+PostMove.swift          — 移动后 size 校验重写 + toggle record 保存
//   +WindowResolution.swift             — WindowIdentity → AXUIElement 四级解析
// 注意：runShellCommand 虽与 move 无关，但被 TitleEditor/TerminalContext 多处调用，
// 保留在 WindowManager 命名空间原位（搬动需同步评估全部调用方，本轮不做）。

// MARK: - Window Move Operations
@MainActor
extension WindowManager {

    func runShellCommand(_ executable: String, args: [String]) -> String? {
        // P-INST-195: WindowManager shell 命令执行入口耗时（委托 ShellRunner.run fork P-INST-49；窗口移动相关 shell 调用，≥50ms warn 归因调用点）。
        #if PERF_INSTRUMENT
        let rscStart = Date()
        #endif
        let stdout = ShellRunner.run(executable: executable, arguments: args)?.stdout
        #if PERF_INSTRUMENT
        let durMs = elapsedMilliseconds(since: rscStart)
        if durMs >= 50 { log("[WindowManager] runShellCommand slow", level: .warn, fields: ["executable": executable, "durationMs": String(durMs)]) }
        #endif
        return stdout
    }

    /// 经 yabai `--move abs` + `--resize abs` 把窗口 frame 直写到位（跨 display 可靠）。
    ///
    /// ## 场景（2026-09-01 toggle 跨屏失效修复）
    /// - yabai v7 float 布局下 `window --space` 静默失效（exit 0 窗口不动，
    ///   Tests/AXMoveValidation.swift T3 断言实测），跨 display 移动改用 frame 直写：
    ///   macOS 窗口归属跟随物理位置，自动切到目标 display 的 visible space
    ///   （T3 断言 PASS：space 1→5、display 1→3，挪回亦 PASS）。
    /// - 前置条件：窗口已 float（managed 窗口的 --move 被拒或被 re-tile 对抗）。
    /// - 写入顺序自适应（2026-09-03 乱蹦修复，见 FrameWriteOrder 场景注释）：收窄先
    ///   resize 后 move，放大先 move 后 resize，使两段之间的中间态窗口被源屏或目标
    ///   frame 包含，中心不落第三方 display。
    /// - 段间等生效（2026-09-03 乱蹦二次修复）：fork 返回 ≠ 窗口服务已应用——仅按
    ///   发令排序不够（实测 move 落地时 resize 尚未生效，yabai 把仍全屏尺寸的窗口
    ///   clamp 到目标屏可视区顶边），第一段必须轮询到效果可观测再发第二段。
    /// - resize 走 AX（2026-09-04 混合写入）：resize 段窗口未跨屏（源屏收窄/已达
    ///   目标屏放大），AX 同屏写有效且无进程 fork（~25ms vs yabai fork 40-90ms）；
    ///   AX 不可写（属性只读/解析失败）时 fallback yabai resize。move 恒走 yabai
    ///   （跨屏唯一可靠通道）。
    /// - 段二后轮询验证（origin+size 双维度，25ms 节拍、400ms 预算，早收敛早返回；
    ///   未收敛重写一次）——2026-09-03 由固定 400ms settle 改轮询（水感优化）。
    /// - 按偏差补发（2026-09-03 clamp 修复）：收敛循环的每次重写读当前 bounds，origin
    ///   已达标只补 resize、size 已达标只补 move、全不达标按写序两段——重写发「缺的那段」
    ///   而非固定第二段，使 clamp（如先 resize 被钳到源屏可视高）在窗口落目标屏后自愈。
    /// - sourceVisibleFrame：窗口当前所在 display 的可视区（供顺序判定避开 clamp + 放大序
    ///   源屏先行判定，见 FrameConvergence.writeOrder）；nil 时退回纯收窄/放大判定。
    /// - 停滞重发 + AX 失败降级（2026-09-06 水波/慢修复）：收敛轮询内连续 4 读不变即幂等
    ///   补发缺失段（写丢失不再干等整轮 400ms）；AX resize 一轮不收敛后，后续补发改走
    ///   yabai 通道（不再对吞写的 app 撞死胡同）。
    /// - Returns: 最终验证是否收敛到目标 frame。
    func moveWindowToFrameViaYabai(
        windowID: UInt32,
        frame: CGRect,
        op: String,
        stage: String,
        sourceVisibleFrame: CGRect?
    ) -> Bool {
        let segStart = Date()
        var axResizeWriteMs = 0
        var axResizeSendCount = 0
        var yabaiSendCount = 0
        var attemptNo = 0
        // 写前 frame 快照：顺序判定依据（查询失败走历史顺序，见 FrameConvergence.writeOrder）。
        let preWriteBounds = cgWindowBounds(for: windowID)
        let writeOrder = FrameConvergence.writeOrder(
            currentSize: preWriteBounds?.size,
            targetSize: frame.size,
            sourceVisibleSize: sourceVisibleFrame?.size,
            currentFrame: preWriteBounds,
            sourceVisibleFrame: sourceVisibleFrame
        )
        log("[WindowManager] moveWindowToFrameViaYabai: write order", level: .debug, fields: [
            "op": op, "stage": stage, "windowID": String(windowID),
            "order": writeOrder == .resizeThenMove ? "resize_then_move" : "move_then_resize",
            "target": QuartzRect(frame).description
        ])
        let applyMove = {
            yabaiSendCount += 1
            _ = self.spaceController.runYabai(
                arguments: ["-m", "window", "\(windowID)", "--move", "abs:\(Int(frame.origin.x)):\(Int(frame.origin.y))"],
                operation: "\(stage).move(windowID=\(windowID))",
                operationID: op
            )
        }
        let applyResize = {
            yabaiSendCount += 1
            _ = self.spaceController.runYabai(
                arguments: ["-m", "window", "\(windowID)", "--resize", "abs:\(Int(frame.width)):\(Int(frame.height))"],
                operation: "\(stage).resize(windowID=\(windowID))",
                operationID: op
            )
        }
        // 段间等待：轮询第一段效果可观测（早满足早返回），超时也照发第二段——
        // 最终由段二的收敛循环如实裁决，不在此静默失败。
        func waitForPhase(_ label: String, observed: () -> Bool) {
            let outcome = ConditionPolling.waitUntil(
                intervalMs: WindowSettle.frameVerifyPollIntervalMs,
                budgetMs: WindowSettle.framePhaseVerifyBudgetMs,
                condition: observed
            )
            if !outcome.satisfied {
                log("[WindowManager] moveWindowToFrameViaYabai: phase \(label) verify exhausted", level: .warn, fields: [
                    "op": op, "stage": stage, "windowID": String(windowID),
                    "budgetMs": String(WindowSettle.framePhaseVerifyBudgetMs)
                ])
            }
        }
        // AX resize 通道（同屏 resize 无 fork）：窗口 AX 解析失败/属性不可写时 fallback yabai。
        // 解析顺序：yabai queryWindow(pid) → findWindowByPID（queryWindow 走流程内缓存常命中）。
        func resolveAXForResize() -> AXUIElement? {
            guard let info = spaceController.queryWindow(windowID: windowID, ignoreCache: false),
                  let pid = info.pid.map({ pid_t($0) }) else { return nil }
            return findWindowByPID(pid, windowID: windowID)
        }
        let axWindow = resolveAXForResize().flatMap { ax -> AXUIElement? in
            isAttributeSettable(ax, attribute: kAXSizeAttribute) ? ax : nil
        }
        log("[WindowManager] moveWindowToFrameViaYabai: resize channel", level: .debug, fields: [
            "op": op, "stage": stage, "windowID": String(windowID),
            "channel": axWindow != nil ? "ax" : "yabai"
        ])
        // AX size 写（同屏有效）+ CGWindowList 读回；AX 不可写时 yabai resize。
        // axResizeUnreliable：AX 写一轮读回未确认生效（写被 busy app 吞/延迟）后置位，
        // 后续补发改走 yabai——不对已证明吞写的通道反复重试（2026-09-06）。
        var axResizeUnreliable = axWindow == nil
        func applyResizeBestChannel() {
            if let ax = axWindow, !axResizeUnreliable {
                axResizeSendCount += 1
                let writeStart = Date()
                let axOK = resizeViaAX(targetFrame: frame, window: ax, windowID: windowID, op: op, stage: stage)
                axResizeWriteMs += elapsedMilliseconds(since: writeStart)
                if !axOK { axResizeUnreliable = true }
            } else {
                applyResize()
            }
        }
        let phase1Start = Date()
        switch writeOrder {
        case .resizeThenMove:
            applyResizeBestChannel()
            waitForPhase("resize", observed: {
                guard let current = cgWindowBounds(for: windowID) else { return false }
                return CoordinateKit.isSizeConverged(actual: current.size, target: frame.size, tolerance: frameTolerance)
            })
            applyMove()
        case .moveThenResize:
            applyMove()
            waitForPhase("move", observed: {
                guard let current = cgWindowBounds(for: windowID) else { return false }
                return CoordinateKit.originDrift(current.origin, frame.origin) <= frameTolerance
            })
            applyResizeBestChannel()
        }
        let phase1Elapsed = elapsedMilliseconds(since: phase1Start)
        // 段二 + 全帧收敛验证（轮询版：写→每 25ms 读，一收敛即返回，400ms 预算兜底）。
        // 重写按偏差补发缺的那段（origin✓size✗→resize / origin✗size✓→move / 全✗按写序），
        // 使 clamp 在窗口落目标屏后自愈。停滞重发（连续 4 读不变）在轮询内幂等补发，
        // 写丢失不再干等整轮预算。注：轮询读不逐次记 mismatch 日志（25ms 节拍会刷屏），
        // 只在整轮耗尽时记一次。
        let phase2Start = Date()
        let outcome = FrameConvergence.convergeFramePolling(
            attempts: 2,
            intervalMs: WindowSettle.frameVerifyPollIntervalMs,
            budgetMs: WindowSettle.frameVerifyBudgetMs,
            write: {
                attemptNo += 1
                let current = cgWindowBounds(for: windowID)
                let originOK = current.map { CoordinateKit.originDrift($0.origin, frame.origin) <= frameTolerance } ?? false
                let sizeOK = current.map { CoordinateKit.isSizeConverged(actual: $0.size, target: frame.size, tolerance: frameTolerance) } ?? false
                switch (originOK, sizeOK) {
                case (true, false):
                    applyResizeBestChannel()
                case (false, true):
                    applyMove()
                case (false, false):
                    if writeOrder == .resizeThenMove {
                        applyResize()
                        applyMove()
                    } else {
                        applyMove()
                        applyResize()
                    }
                case (true, true):
                    break // 已收敛，无需写（防御分支，轮询会立即判收敛返回）
                }
                // yabai 写不返回硬失败（exit code 吞掉，最终以读回判据为准）。
                return true
            },
            read: { cgWindowBounds(for: windowID) },
            isConverged: { CoordinateKit.isFrameConverged(actual: $0, target: frame, tolerance: frameTolerance) },
            stallResendReads: 4
        )
        let phase2Elapsed = elapsedMilliseconds(since: phase2Start)
        // 停滞重发次数 = write 闭包总调用数 − 收敛轮数（重发发生在轮询内，不换轮）。
        let convergedRounds: Int
        switch outcome {
        case .converged(let attempt, _):
            convergedRounds = attempt
        case .mismatched(let attempts, _):
            convergedRounds = attempts
        case .writeFailed(let attempt):
            convergedRounds = attempt
        }
        let resendCount = max(0, attemptNo - convergedRounds)
        // 段级计时汇总（INFO 恒开）：下次「副→主慢」投诉可直接按 op 抽本行归因，
        // 不再需要猜测负载或加埋点重编（2026-09-06 排查教训：段内无数据干猜 5 小时）。
        log("[WindowManager] moveWindowToFrameViaYabai: segment timing", level: .info, fields: [
            "op": op, "stage": stage, "windowID": String(windowID),
            "order": writeOrder == .resizeThenMove ? "resize_then_move" : "move_then_resize",
            "phase1Ms": String(phase1Elapsed),
            "phase2ConvergeMs": String(phase2Elapsed),
            "totalMs": String(elapsedMilliseconds(since: segStart)),
            "axResizeSendCount": String(axResizeSendCount),
            "axResizeWriteMs": String(axResizeWriteMs),
            "axResizeUnreliable": String(axResizeUnreliable),
            "yabaiSendCount": String(yabaiSendCount),
            "convergeRounds": String(convergedRounds),
            "stallResendCount": String(resendCount)
        ])
        switch outcome {
        case .converged(let attempt, _):
            log("[WindowManager] moveWindowToFrameViaYabai: verified", level: .debug, fields: [
                "op": op, "stage": stage, "windowID": String(windowID), "attempt": String(attempt)
            ])
            return true
        case .mismatched(let attempts, let lastFrame):
            log("[WindowManager] moveWindowToFrameViaYabai: frame not converged after \(attempts) attempts", level: .warn, fields: [
                "op": op, "stage": stage, "windowID": String(windowID),
                "lastFrame": lastFrame.map { QuartzRect($0).description } ?? "nil",
                "target": QuartzRect(frame).description,
                "originDrift": lastFrame.map { String(Int(CoordinateKit.originDrift($0.origin, frame.origin))) } ?? "nil",
                "sizeDrift": lastFrame.map { String(Int(CoordinateKit.sizeDrift($0.size, frame.size))) } ?? "nil"
            ])
            return false
        case .writeFailed:
            // writeFailed 对 yabai 写不可达（防御分支）。
            return false
        }
    }

    /// Move a specific window to the main screen with proper space and size handling.
    ///
    /// This is the implementation method for `moveToMainScreen`, handling:
    /// 1. Space context capture (source space/display for future restore)
    /// 2. Yabai space move (for cross-display moves) or AX positioning
    /// 3. Float window (detach from yabai tiling)
    /// 4. Apply fullscreen size on main screen
    /// 5. Save toggle record for restore
    /// 6. Post-move size verification and correction
    ///
    /// ## 场景
    /// - moveToMainScreen（toggle move_to_main 分支）的实现体；hook 自动恢复等路径
    ///   也经 moveWindowToMainScreen 进入。
    ///
    /// ## 两条解析路径（P2 机制，必读）
    /// - **AX 路径**（knownWindowAX != nil）：toggle 入口已 AX 解析，直接复用；窗口仍在
    ///   副屏，size readback 跨屏阻塞（task #7 回退教训），保持 size 先（positionFirst=false）。
    /// - **yabai 路径**（knownWindowAX == nil）：先 yabai space move 到主屏 visible space
    ///   （focus=false 不切用户视角），再 resolveWindow（窗口已主屏，AX 不阻塞）。
    ///   yabai space move 是跨屏移动唯一可靠手段（SLS 无权限，memory
    ///   space_switch_regression）；apply 用 position 先 + settle，避免 size 被副屏
    ///   visibleFrame clamp（sizeDrift=372 半屏 bug）。
    ///
    /// ## 竞态/历史 bug
    /// - origFrame 必须用 space move 之前的快照（knownOrigFrame）：P2 路径 frame(of:) 在
    ///   space move 之后调用会被 yabai re-tile 污染（a049a86 副屏单窗口尺寸缩小）。
    /// - float 必须先于 apply：窗口被 yabai tiled 时 AX size write 会被 re-tile 覆盖
    ///   （实测 height 卡副屏高 707）；先 toggle float 脱离 yabai 管理再设 size。
    ///
    /// - Parameters:
    ///   - identity: Window identity (windowID, pid, bundleID, title, etc.)
    ///   - reason: Why this move is happening (manualHotkey, hookAutoRestore, etc.)
    ///   - sessionID: Optional session identifier for hook-related moves
    ///   - operationID: Unique operation identifier (auto-generated if nil)
    ///   - knownWindowAX: Pre-resolved AXUIElement to avoid redundant AX queries
    ///   - knownOrigFrame: Pre-captured original frame (avoids reading post-space-move frame in P2 yabai path)
    /// - Returns: true if move succeeded, false otherwise
    @discardableResult
    func moveWindowToMainScreen(
        identity: WindowIdentity,
        reason: WindowMoveReason,
        sessionID: String?,
        operationID: String? = nil,
        knownWindowAX: AXUIElement? = nil,
        knownOrigFrame: CGRect? = nil
    ) -> Bool {
        let op = operationID ?? makeOperationID(prefix: "move")
        let startedAt = Date()
        log("[WindowManager] moveWindowToMainScreen started", fields: [
            "op": op,
            "windowID": String(identity.windowID),
            "pid": String(identity.pid),
            "reason": reason.rawValue,
            "sessionID": sessionID ?? "nil"
        ])

        guard hasAccessibilityPermission() else {
            log("moveWindowToMainScreen failed: accessibility not granted", level: .error, fields: ["op": op])
            notifyAccessibilityPermissionRequired()
            return false
        }

        // P2: captureSpaceContext 必须在 window move 之前（sourceSpace = 移动前 space）。
        // AX 路径（knownWindowAX != nil）和 yabai 路径都依赖此 sourceSpace 供 restore 移回。
        // 提前到 windowAX 解析前：yabai 路径会先 yabai space move 改变窗口 space，必须在 move 前捕获。
        // P-INST-3: captureSpaceContextMs 诊断移动前 space 上下文捕获（含 queryWindow + querySpaces + visibleSpaceIndex）。
        let captureCtxStart = Date()
        let spaceContext = spaceController.captureSpaceContext(windowID: identity.windowID, operationID: op)
        let captureSpaceContextMs = elapsedMilliseconds(since: captureCtxStart)

        // P2: windowAX 解析分两路径（详见文件头"两条解析路径"）。
        let windowAX: AXUIElement
        var p2YabaiSpaceMoveMs = 0
        // P-INST-3: yabai 路径子阶段计时（visibleSpaceIndex + resolveWindow，AX 路径恒 0）。
        var visibleSpaceIndexMs = 0
        var resolveWindowMs = 0
        // P2 路径是否已完成 float 脱管（决定 apply 段是否跳过 setWindowFloat，防止二次 toggle）
        var preFloatApplied = false
        if let knownAX = knownWindowAX {
            windowAX = knownAX
        } else {
            // 主屏 visible space 编号（restore record 需要；窗口归属由 frame 直写自动跟随）
            let visibleSpaceStart = Date()
            let visibleSpace = spaceController.visibleSpaceIndex(forDisplayIndex: 1)?.yabaiIndex
            visibleSpaceIndexMs = elapsedMilliseconds(since: visibleSpaceStart)
            guard let mainScreenSpaceIndex = visibleSpace else {
                log("moveWindowToMainScreen P2 failed: cannot resolve main screen visible space", level: .error, fields: ["op": op])
                return false
            }
            // 2026-09-01 重构（toggle 跨屏移动失效修复）：
            // yabai v7 float 布局下 `window --space` 静默失效（exit 0 但窗口不动，
            // Tests/AXMoveValidation.swift T3 断言实测），不再使用。跨屏移动改为：
            // float 脱管（--toggle float；yabai 会对新 float 窗口默认重摆，必须等 300ms
            // 重摆落定）→ `--move abs` + `--resize abs` 直写主屏目标 frame（窗口归属跟随
            // 物理位置自动切 display，T3 断言 PASS）。p2YabaiSpaceMoveMs 字段语义变更为
            // float+settle 耗时（诊断字段名兼容保留）。
            preFloatApplied = true
            let preFloatStart = Date()
            // 已 float 零等待（skippedNoOp 无重摆）；真 toggle 时等稳定代等固定
            // （waitForRelayout：下限防静默误判，连续两读相等即走，300ms 总预算兜底）。
            var p2FloatToggled = false
            if let info = spaceController.queryWindow(windowID: identity.windowID), !info.isFloating {
                let floatOutcome = spaceController.setWindowFloat(identity.windowID, operationID: op, knownWindowInfo: info)
                p2FloatToggled = floatOutcome.didToggle
            }
            if p2FloatToggled {
                FrameConvergence.waitForRelayout(
                    minSettleMicros: WindowSettle.floatRelayoutMinSettleMicros,
                    intervalMs: WindowSettle.frameVerifyPollIntervalMs,
                    budgetMs: WindowSettle.floatRelayoutSettleMicros,
                    read: { cgWindowBounds(for: identity.windowID) },
                    isSame: { CoordinateKit.isFrameConverged(actual: $1, target: $0, tolerance: frameTolerance) }
                )
            }
            p2YabaiSpaceMoveMs = elapsedMilliseconds(since: preFloatStart)
            log("[WindowManager] moveWindowToMainScreen P2: float + settle", fields: [
                "op": op, "windowID": String(identity.windowID),
                "mainScreenSpace": String(mainScreenSpaceIndex),
                "floatToggled": String(p2FloatToggled),
                "durationMs": String(p2YabaiSpaceMoveMs)
            ])
            spaceController.clearWindowQueryCache()
            // 窗口物理仍在源屏，AX resolveWindow 可能跨屏阻塞一次（~68ms，可接受）
            let resolveStart = Date()
            let resolvedAXOpt = resolveWindow(identity: identity)
            resolveWindowMs = elapsedMilliseconds(since: resolveStart)
            guard let resolvedAX = resolvedAXOpt else {
                log("moveWindowToMainScreen P2 failed: cannot resolve window", level: .error, fields: ["op": op])
                return false
            }
            windowAX = resolvedAX
        }

        // P-INST-3: frameReadMs 诊断 AX frame(of:) 读取（窗口已在主屏 space，应 <20ms；若高说明 AX 跨屏阻塞）。
        // BUG FIX: In P2 yabai path, frame(of:) is called AFTER yabai space move, which may have
        // already re-tiled the window, causing origFrame to be corrupted (wrong size). Use knownOrigFrame
        // (captured BEFORE space move) when available.
        let frameReadStart = Date()
        let origFrame: CGRect?
        if let preCapturedFrame = knownOrigFrame {
            origFrame = preCapturedFrame
            log("[WindowManager] moveWindowToMainScreen: using pre-captured origFrame (P2 yabai path)", fields: [
                "op": op,
                "windowID": String(identity.windowID),
                "origFrame": QuartzRect(preCapturedFrame).description,
                "source": "knownOrigFrame"
            ])
        } else {
            let axFrame = frame(of: windowAX)
            origFrame = axFrame
            log("[WindowManager] moveWindowToMainScreen: using AX frame read", fields: [
                "op": op,
                "windowID": String(identity.windowID),
                "origFrame": axFrame.map { "\($0.origin.x),\($0.origin.y) \($0.width)x\($0.height)" } ?? "nil",
                "source": "AX"
            ])
        }
        let frameReadMs = elapsedMilliseconds(since: frameReadStart)
        guard let origFrame = origFrame else {
            log("moveWindowToMainScreen failed: cannot read current frame", level: .error, fields: ["op": op])
            return false
        }

        log("[WindowManager] moveWindowToMainScreen: space context captured", fields: [
            "op": op,
            "windowID": String(identity.windowID),
            "sourceSpaceIndex": spaceContext.sourceSpaceIndex.map { String(describing: $0) } ?? "nil",
            "sourceDisplayIndex": spaceContext.sourceDisplayIndex.map { String(describing: $0) } ?? "nil",
            "sourceDisplaySpaceIndex": String(spaceContext.sourceDisplaySpaceIndex ?? -1),
            "origFrame": QuartzRect(origFrame).description
        ])

        // Skip if already on main screen — 仅 AX 路径检查。
        // P2 yabai 路径已主动把窗口移到主屏 space，但 frame size 可能仍是副屏尺寸（yabai space move
        // 不 resize），需继续 apply 全屏 size，不能 skip。一次性查询窗口信息，后续复用缓存。
        // P-INST-3: queryWindowMs 诊断移动前窗口信息查询（toggle 入口已缓存通常命中 ~0ms，未命中则 fork）。
        let queryWindowStart = Date()
        let windowInfo = spaceController.queryWindow(windowID: identity.windowID)
        let queryWindowMs = elapsedMilliseconds(since: queryWindowStart)
        if knownWindowAX != nil {
            let yabaiDisplay = windowInfo?.display.map { DisplayIdentifier.yabai($0) }
            if let display = yabaiDisplay?.yabaiIndex, display == 1 {
                if let mainScreen = getMainScreen() {
                    let windowCenter = CGPoint(x: origFrame.midX, y: origFrame.midY)
                    if mainScreen.frame.contains(windowCenter) {
                        log("[WindowManager] moveWindowToMainScreen skipped: already on main screen", fields: [
                            "op": op, "windowID": String(identity.windowID)
                        ])
                        return true
                    }
                }
            }
        }

        // P-INST-3: settableCheckMs 诊断两次 AX isAttributeSettable 检查（应 <5ms）。
        let settableStart = Date()
        let posSettable = isAttributeSettable(windowAX, attribute: kAXPositionAttribute)
        let sizeSettable = isAttributeSettable(windowAX, attribute: kAXSizeAttribute)
        let settableCheckMs = elapsedMilliseconds(since: settableStart)
        guard posSettable, sizeSettable else {
            log("moveWindowToMainScreen failed: window attributes not settable", level: .error, fields: ["op": op])
            return false
        }

        guard let mainScreen = getMainScreen() else {
            log("moveWindowToMainScreen failed: cannot determine main screen", level: .error, fields: ["op": op])
            return false
        }

        let targetFrame = axFrame(forVisibleFrameOf: mainScreen)
        let targetDisplayID = displayID(for: mainScreen)
        let targetDisplayIndex = displayIndex(forDisplayID: targetDisplayID)

        // CGWindowID 跨屏移动后不变，提前计算并复用给 save record。
        let effectiveWindowID = windowHandle(for: windowAX) ?? identity.windowID
        // floatMs：float 脱管+settle 的耗时（P2 路径=p2YabaiSpaceMoveMs；AX 路径=固定 300ms settle）
        let floatMs = preFloatApplied ? p2YabaiSpaceMoveMs : 300

        let applyStart = Date()
        if preFloatApplied {
            // P2 路径：float 已在 resolve 前完成（见上方"float + settle"注释）。
            // 跨屏移动用 yabai --move abs/--resize abs 直写主屏目标 frame（T3 断言验证：
            // 裸 AX position 写会被 WindowServer clamp 在源屏，只有 yabai 的 frame 写能跨 display）。
            // sourceVisibleFrame：窗口当前所在副屏的可视区——供写序判定避开 clamp +
            // 放大序源屏先行判定（副→主：目标尺寸必 ≤ 副屏可视区，resize 在源屏先行
            // 完成，窗口以终态落主屏，2026-09-06 水波修复）。
            let sourceVisibleFrame = windowInfo?.display
                .flatMap { CoordinateKit.nsScreen(forYabaiDisplayIndex: $0) }
                .map { CoordinateKit.quartzVisibleFrame(of: $0) }
            guard moveWindowToFrameViaYabai(windowID: identity.windowID, frame: targetFrame, op: op, stage: "move_to_main", sourceVisibleFrame: sourceVisibleFrame) else {
                log("moveWindowToMainScreen failed: yabai frame move did not converge", level: .error, fields: [
                    "op": op, "targetFrame": String(describing: targetFrame)
                ])
                return false
            }
        } else {
            // AX 路径：窗口已在主屏 display（同 display AX 写有效），保留 float + apply 原逻辑。
            // 先 float 脱离 yabai 管理，再 apply 设全屏 size —— 顺序关键。
            // 若窗口被 yabai 管理（tiled），apply 的 AX size write 会被 yabai re-tile 覆盖
            // （实测 height 卡副屏高 707）。float toggle 会触发 yabai 默认重摆，
            // 等 300ms 落定后再写（否则写被重摆覆盖，2026-09-01 toggle 尺寸错乱根因）。
            let floatKnownInfo = (effectiveWindowID == identity.windowID) ? windowInfo : nil
            let axFloatOutcome = spaceController.setWindowFloat(effectiveWindowID, operationID: op, knownWindowInfo: floatKnownInfo)
            // 已 float 零等待；真 toggle 时等稳定代等固定（同 P2 注释）。
            if axFloatOutcome.didToggle {
                FrameConvergence.waitForRelayout(
                    minSettleMicros: WindowSettle.floatRelayoutMinSettleMicros,
                    intervalMs: WindowSettle.frameVerifyPollIntervalMs,
                    budgetMs: WindowSettle.floatRelayoutSettleMicros,
                    read: { cgWindowBounds(for: effectiveWindowID) },
                    isSame: { CoordinateKit.isFrameConverged(actual: $1, target: $0, tolerance: frameTolerance) }
                )
            }
            guard apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main", maxAttempts: 3, windowID: effectiveWindowID) else {
                log("moveWindowToMainScreen failed: AX apply failed", level: .error, fields: [
                    "op": op, "targetFrame": String(describing: targetFrame)
                ])
                return false
            }
        }
        let applyMs = elapsedMilliseconds(since: applyStart)

        // Post-move 一致性校验 + size 重写兜底（详见 +MoveWindow+PostMove.swift 场景注释）。
        let postMoveCheckMs = verifyAndCorrectPostMoveSize(
            windowAX: windowAX,
            windowID: effectiveWindowID,
            targetFrame: targetFrame,
            origFrame: origFrame,
            mainScreen: mainScreen,
            op: op
        )

        // Save toggle record（详见 +MoveWindow+PostMove.swift 场景注释）。
        let saveMs = saveToggleRecordForMainMove(
            identity: identity,
            windowID: effectiveWindowID,
            origFrame: origFrame,
            spaceContext: spaceContext,
            targetFrame: targetFrame,
            targetDisplayIndex: targetDisplayIndex,
            reason: reason,
            sessionID: sessionID,
            op: op
        )

        log("[WindowManager] moveWindowToMainScreen finished", fields: [
            "op": op,
            "windowID": String(effectiveWindowID),
            "durationMs": String(elapsedMilliseconds(since: startedAt)),
            "floatMs": String(floatMs),
            "applyMs": String(applyMs),
            "postMoveCheckMs": String(postMoveCheckMs),
            "saveMs": String(saveMs),
            "p2SpaceMoveMs": String(p2YabaiSpaceMoveMs),
            // P-INST-3: 内部子阶段，解释 durationMs - floatMs - applyMs - postMoveCheckMs - saveMs - p2SpaceMoveMs 的差值。
            "captureSpaceContextMs": String(captureSpaceContextMs),
            "visibleSpaceIndexMs": String(visibleSpaceIndexMs),
            "resolveWindowMs": String(resolveWindowMs),
            "frameReadMs": String(frameReadMs),
            "queryWindowMs": String(queryWindowMs),
            "settableCheckMs": String(settableCheckMs)
        ])
        return true
    }
}
