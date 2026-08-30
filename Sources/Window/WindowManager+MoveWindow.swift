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
        if let knownAX = knownWindowAX {
            windowAX = knownAX
        } else {
            // P-INST-3: visibleSpaceIndexMs 诊断主屏 visible space 查询（querySpaces 缓存命中应 <1ms）。
            let visibleSpaceStart = Date()
            let visibleSpace = spaceController.visibleSpaceIndex(forDisplayIndex: 1)?.yabaiIndex
            visibleSpaceIndexMs = elapsedMilliseconds(since: visibleSpaceStart)
            guard let mainScreenSpaceIndex = visibleSpace else {
                log("moveWindowToMainScreen P2 failed: cannot resolve main screen visible space", level: .error, fields: ["op": op])
                return false
            }
            let spaceMoveStart = Date()
            let moved = spaceController.moveWindow(
                identity.windowID,
                toSpace: .yabai(mainScreenSpaceIndex),
                focus: false,
                operationID: op
            )
            p2YabaiSpaceMoveMs = elapsedMilliseconds(since: spaceMoveStart)
            log("[WindowManager] moveWindowToMainScreen P2: yabai space move to main", fields: [
                "op": op, "windowID": String(identity.windowID),
                "mainScreenSpace": String(mainScreenSpaceIndex),
                "moved": String(moved), "spaceMoveMs": String(p2YabaiSpaceMoveMs)
            ])
            // yabai space move 改变窗口 space，clear queryWindow 缓存（否则后续 queryWindow 返回
            // 移动前副屏陈旧值，影响 windowInfo.display 判断）。仅清 windowQueryCache：focus=false 不切
            // 任何 display 的 visible space（visible/index/display 映射不变），spacesQueryCache 保留供
            // 连续 toggle 的 captureSpaceContext 命中省 querySpaces fork（has-focus 字段 SpaceController
            // 侧无消费方）。restore 路径仍用 clearQueryCache（清两个，restore 涉及 space 移回）。
            if moved { spaceController.clearWindowQueryCache() }
            // 窗口已到主屏 space（yabai display 1），AX resolveWindow + frame read 不被副屏阻塞。
            // P-INST-3: resolveWindowMs 诊断窗口主屏后的 AX resolveWindow（focused fast path + 全量遍历 fallback）。
            let resolveStart = Date()
            let resolvedAXOpt = resolveWindow(identity: identity)
            resolveWindowMs = elapsedMilliseconds(since: resolveStart)
            guard let resolvedAX = resolvedAXOpt else {
                log("moveWindowToMainScreen P2 failed: cannot resolve window after space move", level: .error, fields: ["op": op])
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
                "origFrame": "\(Int(preCapturedFrame.origin.x)),\(Int(preCapturedFrame.origin.y)) \(Int(preCapturedFrame.width))x\(Int(preCapturedFrame.height))",
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
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.width))x\(Int(origFrame.height))"
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

        // 先 float 脱离 yabai 管理，再 apply 设全屏 size —— 顺序关键。
        // 若窗口被 yabai 管理（tiled），apply 的 AX size write 会被 yabai re-tile 覆盖，
        // 导致 move_to_main 后窗口 height 不全屏（实测 lingdongditu: width 生效到主屏宽 1646，
        // 但 height 卡在副屏高 707，未达主屏全屏高 1079）。先 toggle float 让窗口脱离 yabai，
        // apply 的 size 才能可靠生效。复用上方 windowInfo（缓存命中），避免再次 queryWindow fork。
        // CGWindowID 跨屏移动后不变，提前计算并复用给 setWindowFloat 和 save record。
        let effectiveWindowID = windowHandle(for: windowAX) ?? identity.windowID
        let floatKnownInfo = (effectiveWindowID == identity.windowID) ? windowInfo : nil
        let floatStart = Date()
        spaceController.setWindowFloat(effectiveWindowID, operationID: op, knownWindowInfo: floatKnownInfo)
        let floatMs = elapsedMilliseconds(since: floatStart)

        // AX apply: move window to main screen + set fullscreen size
        // P3.1: positionFirst 按路径选择（详见文件头"两条解析路径"）。
        // maxAttempts: 3 + 回读验证确保 size 可靠生效，避免单次模式下异步窗口（Electron 等）size 未应用就返回。
        let p2PositionFirst = (knownWindowAX == nil)
        let applyStart = Date()
        guard apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main", maxAttempts: 3, positionFirst: p2PositionFirst, windowID: effectiveWindowID) else {
            log("moveWindowToMainScreen failed: AX apply failed", level: .error, fields: [
                "op": op, "targetFrame": String(describing: targetFrame)
            ])
            return false
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
