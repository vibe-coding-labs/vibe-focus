import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - move_to_main 后处理层
// moveWindowToMainScreen 的两个收尾职责（2026-08-31 从 +MoveWindow.swift 抽出，行为不变）：
// 1. verifyAndCorrectPostMoveSize — 移动后 size 漂移校验与重写（对抗 yabai 异步 re-tile）
// 2. saveToggleRecordForMainMove  — 保存 toggle record 供 restore 回原位

/// move_to_main 收尾的宿主依赖缝（2026-11-19 覆盖率补齐）：CG 回读、size 重写、
/// settle 睡眠、屏上下文与 toggle record 落账全可注入。默认 nil → 生产真实实现；
/// Runner 注入假实现直测无漂移/重写收敛/重写耗尽/回读失败/记录字段推导
/// （零 AX 写、零真实睡眠、零记录库写）。
struct PostMoveEnvironment {
    var cgWindowBounds: (UInt32) -> CGRect?
    var writeSize: (AXUIElement, CGRect) -> Void
    var settle: (useconds_t) -> Void
    /// 帧所在屏的 yabai display 索引（记录推导 fallback 用）
    var displayYabaiIndex: (CGRect) -> Int?
    var saveToggleRecord: (WindowIdentity, UInt32, CGRect, SpaceContext, CGRect, Int?, WindowMoveReason, String?, Bool) -> Void
}

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
        op: String,
        environment: PostMoveEnvironment? = nil
    ) -> Int {
        let postMoveCheckStart = Date()
        func readBounds() -> CGRect? {
            if let environment { return environment.cgWindowBounds(windowID) }
            return cgWindowBounds(for: windowID)
        }
        // P3.5: 移除 usleep(30_000) + frame read 改 CGWindowList（非阻塞）。P3.1 positionFirst +
        // setWindowFloat（move_to_main 窗口已 floating，floatMs=0 skipped）后 yabai 无 re-tile，压测
        // sizeDrift 恒 0（postMoveCheck 从未 rewrite），30ms usleep 等 re-tile 冗余。apply phase2 已
        // usleep 25ms + sizeReadbackMatched 验证，紧随的 CGWindowList 读 frame 时 WindowServer 已更新。
        // drift check + rewrite 保留兜底偶发（memory feedback_apply_float_order）。
        if let finalFrame = readBounds() {
            let sizeDrift = CoordinateKit.sizeDrift(finalFrame.size, targetFrame.size)
            log("[WindowManager] moveWindowToMainScreen: post-move frame check", fields: [
                "op": op,
                "windowID": String(windowID),
                "finalFrame": QuartzRect(finalFrame).description,
                "targetSize": QuartzRect(targetFrame).sizeDescription,
                "sizeDrift": String(Int(sizeDrift))
            ])
            if sizeDrift > frameTolerance {
                // 增强诊断：记录详细的 size drift 上下文
                let mainScreenDPI = mainScreen.backingScaleFactor
                log("[WindowManager] moveWindowToMainScreen: size drifted after move — rewriting size", level: .warn, fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "sizeDrift": String(Int(sizeDrift)),
                    "origFrame": QuartzRect(origFrame).description,
                    "finalFrame": QuartzRect(finalFrame).description,
                    "targetFrame": QuartzRect(targetFrame).description,
                    "mainScreenDPI": String(describing: mainScreenDPI),
                    "frameTolerance": String(Int(frameTolerance))
                ])
                var rewriteAttemptStart = Date()
                var rewriteAttemptNo = 0
                let outcome = FrameConvergence.convergeFrame(
                    attempts: 2,
                    // 第十四刀归一：原 postRewriteSettle 15ms 与 axWriteSettle 25ms 同语义（AX size 写后
                    // 等 WindowServer 落定再读回），取保守大值 25ms；15ms 档已从 WindowSettle 下线。
                    settleMicros: WindowSettle.axWriteSettleMicros,
                    write: {
                        rewriteAttemptNo += 1
                        rewriteAttemptStart = Date()
                        if let environment {
                            environment.writeSize(windowAX, targetFrame)
                        } else {
                            var rewriteSize = CGSize(width: targetFrame.width, height: targetFrame.height)
                            if let rewriteValue = AXValueCreate(.cgSize, &rewriteSize) {
                                _ = AXUIElementSetAttributeValue(windowAX, kAXSizeAttribute as CFString, rewriteValue)
                            }
                        }
                        // AX 结果照历史吞掉（兜底路径，读回判据说话）。
                        return true
                    },
                    read: {
                        guard let postRewriteFrame = readBounds() else { return nil }
                        let postDrift = CoordinateKit.sizeDrift(postRewriteFrame.size, targetFrame.size)
                        log("[WindowManager] moveWindowToMainScreen: post-rewrite check", fields: [
                            "op": op, "windowID": String(windowID),
                            "rewriteAttempt": String(rewriteAttemptNo),
                            "postRewriteFrame": QuartzRect(postRewriteFrame).sizeDescription,
                            "postDrift": String(Int(postDrift)),
                            "rewriteMs": String(elapsedMilliseconds(since: rewriteAttemptStart))
                        ])
                        return postRewriteFrame
                    },
                    isConverged: { CoordinateKit.isSizeConverged(actual: $0.size, target: targetFrame.size, tolerance: frameTolerance) },
                    sleep: { micros in
                        if let environment {
                            environment.settle(micros)
                        } else {
                            usleep(micros)
                        }
                    }
                )
                if case .mismatched = outcome {
                    log("[WindowManager] moveWindowToMainScreen: post-rewrite exhausted", level: .warn, fields: [
                        "op": op, "windowID": String(windowID),
                        "hint": "两次重写后仍 size 漂移——app 硬 clamp，可考虑 yabai --resize 更强手段"
                    ])
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
        op: String,
        singleDisplay: Bool = false,
        environment: PostMoveEnvironment? = nil
    ) -> Int {
        let saveStart = Date()
        let sourceSpaceIndex = spaceContext.sourceSpaceIndex ?? .yabai(0)
        let sourceYabaiIndex: Int?
        if let environment {
            sourceYabaiIndex = environment.displayYabaiIndex(origFrame)
        } else {
            sourceYabaiIndex = displayContext(for: origFrame).yabaiIndex
        }
        let sourceDisplay: DisplayIdentifier = spaceContext.sourceDisplayIndex
            ?? sourceYabaiIndex.map { .yabai($0) } ?? .yabai(0)
        if let environment {
            environment.saveToggleRecord(
                identity, windowID, origFrame, spaceContext, targetFrame,
                targetDisplayIndex, reason, sessionID, singleDisplay
            )
        } else {
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
                reason: reason,
                singleDisplay: singleDisplay
            )
        }
        let saveMs = elapsedMilliseconds(since: saveStart)

        log("[WindowManager] moveWindowToMainScreen: ToggleRecord saved", fields: [
            "op": op,
            "windowID": String(windowID),
            "sourceSpace": String(describing: sourceSpaceIndex),
            "origFrame": QuartzRect(origFrame).originDescription,
            "targetFrame": QuartzRect(targetFrame).originDescription,
            "reason": reason.rawValue,
            "sessionID": sessionID ?? "nil"
        ])
        return saveMs
    }
}
