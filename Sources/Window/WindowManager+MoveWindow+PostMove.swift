import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - move_to_main 后处理层
// moveWindowToMainScreen 的两个收尾职责（2026-08-31 从 +MoveWindow.swift 抽出，行为不变）：
// 1. verifyAndCorrectPostMoveSize — 移动后 size 漂移校验与重写（对抗 yabai 异步 re-tile）
// 2. saveToggleRecordForMainMove  — 保存 toggle record 供 restore 回原位

@MainActor
extension WindowManager {

    /// 移动后一致性校验：读最终 frame，size 漂移超阈值则重写（最多 2 次 + 回读验证）。
    ///
    /// ## 场景
    /// - moveWindowToMainScreen 的 apply 成功后调用（窗口已 floating + 主屏，无跨屏干扰）；
    ///
    /// ## 竞态/历史 bug（必读）
    /// - yabai 的 re-tile 是异步的，可能在 apply 返回后覆盖 Phase 1 写入的 height
    ///   （"半屏高"bug 反复 reopen 的结构性原因：9157d08 删除的 RestoreWatchdog 之后
    ///   move 路径没有等价保护）。本函数是兜底：等 apply 两阶段自身验证完成后，
    ///   用 CGWindowList（非阻塞，热路径禁 AX frame 铁律）读最终 frame 比对。
    /// - rewrite 最多 2 次不进循环：iTerm2 等窗口异步 clamp height，单次 AX write 未必
    ///   生效；两次后仍 drift 说明 app 硬 clamp，日志暴露 postDrift 供更强手段（如
    ///   yabai --resize）。幂等单次调用。
    ///
    /// - Returns: 本阶段耗时（ms），供调用方 finished 汇总日志（postMoveCheckMs）。
    func verifyAndCorrectPostMoveSize(
        windowAX: AXUIElement,
        windowID: UInt32,
        targetFrame: CGRect,
        origFrame: CGRect,
        mainScreen: NSScreen,
        op: String
    ) -> Int {
        let postMoveCheckStart = Date()
        // P3.5: 移除 usleep(30_000) + frame read 改 CGWindowList（非阻塞）。P3.1 positionFirst +
        // setWindowFloat（move_to_main 窗口已 floating，floatMs=0 skipped）后 yabai 无 re-tile，压测
        // sizeDrift 恒 0（postMoveCheck 从未 rewrite），30ms usleep 等 re-tile 冗余。apply phase2 已
        // usleep 25ms + sizeReadbackMatched 验证，紧随的 CGWindowList 读 frame 时 WindowServer 已更新。
        // drift check + rewrite 保留兜底偶发（memory feedback_apply_float_order）。
        if let finalFrame = cgWindowBounds(for: windowID) {
            let sizeDrift = CoordinateKit.sizeDrift(finalFrame.size, targetFrame.size)
            log("[WindowManager] moveWindowToMainScreen: post-move frame check", fields: [
                "op": op,
                "windowID": String(windowID),
                "finalFrame": "\(Int(finalFrame.origin.x)),\(Int(finalFrame.origin.y)) \(Int(finalFrame.width))x\(Int(finalFrame.height))",
                "targetSize": "\(Int(targetFrame.width))x\(Int(targetFrame.height))",
                "sizeDrift": String(Int(sizeDrift))
            ])
            if sizeDrift > frameTolerance {
                // 增强诊断：记录详细的 size drift 上下文
                let mainScreenDPI = mainScreen.backingScaleFactor
                log("[WindowManager] moveWindowToMainScreen: size drifted after move — rewriting size", level: .warn, fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "sizeDrift": String(Int(sizeDrift)),
                    "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.width))x\(Int(origFrame.height))",
                    "finalFrame": "\(Int(finalFrame.origin.x)),\(Int(finalFrame.origin.y)) \(Int(finalFrame.width))x\(Int(finalFrame.height))",
                    "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.width))x\(Int(targetFrame.height))",
                    "mainScreenDPI": String(describing: mainScreenDPI),
                    "frameTolerance": String(Int(frameTolerance))
                ])
                for rewriteAttempt in 1...2 {
                    // P-INST-11: 每次 rewrite 耗时（AX write + usleep15 + cgWindowBounds readback，正常 ~17ms）。
                    let rewriteAttemptStart = Date()
                    var rewriteSize = CGSize(width: targetFrame.width, height: targetFrame.height)
                    if let rewriteValue = AXValueCreate(.cgSize, &rewriteSize) {
                        _ = AXUIElementSetAttributeValue(windowAX, kAXSizeAttribute as CFString, rewriteValue)
                    }
                    usleep(WindowSettle.postRewriteSettleMicros)
                    guard let postRewriteFrame = cgWindowBounds(for: windowID) else { break }
                    let postDrift = CoordinateKit.sizeDrift(postRewriteFrame.size, targetFrame.size)
                    log("[WindowManager] moveWindowToMainScreen: post-rewrite check", fields: [
                        "op": op, "windowID": String(windowID),
                        "rewriteAttempt": String(rewriteAttempt),
                        "postRewriteFrame": "\(Int(postRewriteFrame.width))x\(Int(postRewriteFrame.height))",
                        "postDrift": String(Int(postDrift)),
                        "rewriteMs": String(elapsedMilliseconds(since: rewriteAttemptStart))
                    ])
                    if postDrift <= frameTolerance { break }
                }
            }
        }
        return elapsedMilliseconds(since: postMoveCheckStart)
    }

    /// 保存 toggle record——即使 yabai 拿不到 space 信息也保存
    /// （sourceSpace=0 语义为"无 space 信息，restore 时跳过 yabai space move"）。
    ///
    /// ## 场景
    /// - moveWindowToMainScreen 收尾调用；origFrame 必须是 space move 之前的快照
    ///   （P2 yabai 路径用 knownOrigFrame，否则移动后读到的已是主屏新 frame）。
    ///
    /// - Returns: 本阶段耗时（ms），供调用方 finished 汇总日志（saveMs）。
    func saveToggleRecordForMainMove(
        identity: WindowIdentity,
        windowID: UInt32,
        origFrame: CGRect,
        spaceContext: SpaceContext,
        targetFrame: CGRect,
        targetDisplayIndex: Int?,
        reason: WindowMoveReason,
        sessionID: String?,
        op: String
    ) -> Int {
        let saveStart = Date()
        let sourceSpaceIndex = spaceContext.sourceSpaceIndex ?? .yabai(0)
        let sourceContext = displayContext(for: origFrame)
        let sourceDisplay: DisplayIdentifier = spaceContext.sourceDisplayIndex ?? sourceContext.index.map { .yabai($0) } ?? .yabai(0)
        ToggleEngine.shared.save(
            windowID: windowID,
            pid: identity.pid,
            bundleIdentifier: identity.bundleIdentifier,
            appName: identity.appName,
            origFrame: origFrame,
            sourceSpace: sourceSpaceIndex,
            sourceDisplay: sourceDisplay,
            sourceYabaiDisp: spaceContext.sourceDisplayIndex ?? .yabai(0),
            sourceDispSpace: spaceContext.sourceDisplaySpaceIndex ?? 0,
            targetFrame: targetFrame,
            targetDisplay: targetDisplayIndex ?? 0,
            sessionID: sessionID,
            reason: reason
        )
        let saveMs = elapsedMilliseconds(since: saveStart)

        log("[WindowManager] moveWindowToMainScreen: ToggleRecord saved", fields: [
            "op": op,
            "windowID": String(windowID),
            "sourceSpace": String(describing: sourceSpaceIndex),
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y))",
            "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y))",
            "reason": reason.rawValue,
            "sessionID": sessionID ?? "nil"
        ])
        return saveMs
    }
}
