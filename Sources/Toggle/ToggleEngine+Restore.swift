import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

// MARK: - Restore Logic

@MainActor
extension ToggleEngine {

    // MARK: - Restore 执行

    /// 执行恢复：移动窗口回原始位置 + 切换到原始 space
    /// fallbackPID: 当 windowID 查不到 record 时，用 PID 回退查找
    @discardableResult
    func restore(windowID: UInt32, fallbackPID: Int32? = nil, triggerSource: String, traceID: String? = nil) -> Bool {
        let trace = traceID ?? makeOperationID(prefix: "te")
        var record = load(windowID: windowID)
        var usedPIDFallback = false

        if record == nil, let pid = fallbackPID {
            record = loadByPID(pid: pid)
            if record != nil {
                usedPIDFallback = true
                log("[ToggleEngine] restore: windowID lookup failed, found record by PID fallback", level: .info, fields: [
                    "traceID": trace,
                    "windowID": String(windowID),
                    "pid": String(pid),
                    "storedWindowID": String(record!.windowID)
                ])
            }
        }

        guard let record else {
            log("ToggleEngine.restore: no toggle record found", level: .warn, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "fallbackPID": fallbackPID.map { String($0) } ?? "nil"
            ])
            return false
        }

        log("ToggleEngine.restore: starting", level: .info, fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "sourceSpace": String(record.sourceSpace),
            "sourceDisplay": String(record.sourceDisplay),
            "sourceYabaiDisp": String(record.sourceYabaiDisp),
            "sourceDispSpace": String(record.sourceDispSpace),
            "triggerSource": triggerSource,
            "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y)) \(Int(record.origFrame.width))x\(Int(record.origFrame.height))"
        ])

        // 校验 origFrame 坐标是否在已知屏幕范围内
        // origFrame 是 AppKit 坐标（来自 AX API），直接用 NSScreen.frame（也是 AppKit）比较
        let origCenter = CGPoint(x: record.origFrame.midX, y: record.origFrame.midY)
        let onAnyScreen = NSScreen.screens.contains { screen in
            screen.frame.insetBy(dx: -200, dy: -200).contains(origCenter)
        }
        if !onAnyScreen {
            log(
                "[ToggleEngine] restore: origFrame not on any screen, skipping restore (data preserved)",
                level: .warn,
                fields: [
                    "traceID": trace,
                    "windowID": String(windowID),
                    "origFrame": "\(record.origFrame)",
                    "screens": NSScreen.screens.map { "\($0.frame)" }.joined(separator: ", ")
                ]
            )
            return false
        }

        let wm = WindowManager.shared
        let spaceController = SpaceController.shared

        // PID fallback 时，record.windowID 是旧的 CGWindowNumber，
        // 当前窗口的 windowID 是函数参数 windowID，用当前值查找 AX
        let axLookupWindowID = usedPIDFallback ? windowID : record.windowID

        // 1. 找到窗口 AX element
        guard let windowAX = wm.findWindowByPID(record.pid, windowID: axLookupWindowID) else {
            log("ToggleEngine.restore: window AX element not found", level: .warn, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "axLookupWindowID": String(axLookupWindowID),
                "pid": String(record.pid),
                "usedPIDFallback": String(usedPIDFallback)
            ])
            return false
        }

        // PID fallback 时，后续操作使用当前 windowID（AX 层面的真实 ID）
        let effectiveWindowID = usedPIDFallback ? windowID : record.windowID

        // 2. 记录当前 frame（日志用，不阻止 restore）
        // 之前这里会检查 isNearTarget 并在偏移>200px 时拒绝 restore
        // 但窗口在主屏停留期间 yabai/macOS/用户都可能调整位置，这是正常行为
        // 只要窗口还在主屏幕上（由 HookEventHandler 的 isOnMain 检查），就应该恢复
        let currentFrame = wm.frame(of: windowAX)
        if let cf = currentFrame {
            let xOffset = abs(cf.origin.x - record.targetFrame.origin.x)
            let yOffset = abs(cf.origin.y - record.targetFrame.origin.y)
            if xOffset > 200 || yOffset > 200 {
                log("ToggleEngine.restore: window drifted from target, proceeding anyway", level: .info, fields: [
                    "traceID": trace,
                    "windowID": String(windowID),
                    "currentFrame": "\(Int(cf.origin.x)),\(Int(cf.origin.y)) \(Int(cf.size.width))x\(Int(cf.size.height))",
                    "targetFrame": "\(Int(record.targetFrame.origin.x)),\(Int(record.targetFrame.origin.y)) \(Int(record.targetFrame.size.width))x\(Int(record.targetFrame.size.height))",
                    "xOffset": String(Int(xOffset)),
                    "yOffset": String(Int(yOffset))
                ])
            }
        }

        // 2.5 检测 SA 可用性 — 如果上次操作遇到 SA 错误，刷新状态
        // 避免 restore 过程中反复尝试已经失败的 yabai SA 命令
        if !spaceController.canControlSpaces {
            log("[ToggleEngine] restore: SA not available, forcing refresh before restore", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID)
            ])
            spaceController.refreshAvailability(force: true)
        }

        // 3.5 记录所有 display 当前可见 space（用于 restore 后检测意外切换）
        // 注意：setWindowFloat 必须在 moveWindow 之后调用（在目标 Space 上设 float），
        // 不能在这里提前调用——yabai 的 float 状态不会跨 Space 传递
        var preRestoreDisplaySpaces: [Int: Int] = [:]
        for disp in 1...displayCount {
            if let vis = spaceController.displayVisibleSpace(displayIndex: .yabai(disp)) {
                preRestoreDisplaySpaces[disp] = vis.yabaiIndex ?? 0
            }
        }
        var restored = false

        // 跟踪所有在 restore 过程中被故意切换的 display
        // 不仅包括 sourceYabaiDisp（目标 display），还包括 switchDisplayToSpace 中切换的其他 display
        var intentionallySwitchedDisplays: Set<Int> = [record.sourceYabaiDisp]

        let needCrossDisplayMove = record.sourceYabaiDisp != 1

        log("[ToggleEngine] restore: captured pre-restore display spaces", level: .debug, fields: [
            "traceID": trace,
            "preRestoreDisplaySpaces": preRestoreDisplaySpaces.map { "d\($0.key)=s\($0.value)" }.joined(separator: ","),
            "needCrossDisplayMove": String(needCrossDisplayMove),
            "intentionallySwitchedDisplays": intentionallySwitchedDisplays.sorted().map { "d\($0)" }.joined(separator: ",")
        ])

        // 4. 执行 restore
        if needCrossDisplayMove {
            restored = performCrossDisplayRestore(
                record: record,
                windowAX: windowAX,
                effectiveWindowID: effectiveWindowID,
                triggerSource: triggerSource,
                traceID: trace,
                intentionallySwitchedDisplays: &intentionallySwitchedDisplays
            )
        } else {
            restored = wm.apply(frame: record.origFrame, to: windowAX, operationID: trace, stage: "restore_orig")

            if restored {
                if let postFrame = wm.frame(of: windowAX) {
                    let onMainScreen = CoordinateKit.isOnMainScreen(postFrame)
                    if onMainScreen {
                        log("[ToggleEngine] restore: AX apply moved window to correct screen", fields: [
                            "traceID": trace,
                            "windowID": String(windowID),
                            "origFrame": "\(record.origFrame)"
                        ])
                    }
                }

                switchToOriginalSpace(
                    record: record,
                    windowAX: windowAX,
                    effectiveWindowID: effectiveWindowID,
                    triggerSource: triggerSource,
                    traceID: trace,
                    intentionallySwitchedDisplays: &intentionallySwitchedDisplays
                )
            } else {
                log("ToggleEngine.restore: AX apply failed, no fallback available", level: .error, fields: [
                    "traceID": trace,
                    "windowID": String(windowID)
                ])
            }
        }

        // 6. 检测并修复 CGEvent 意外切换其他 display
        if restored, !preRestoreDisplaySpaces.isEmpty {
            fixAccidentalDisplaySwitches(
                preRestoreDisplaySpaces: preRestoreDisplaySpaces,
                intentionallySwitchedDisplays: intentionallySwitchedDisplays,
                traceID: trace
            )
        }

        // 启动 post-restore watchdog
        // yabai 异步 tiling 引擎可能在 restore 完成后撤销操作
        if restored {
            RestoreWatchdog.shared.startMonitoring(target: RestoreWatchdog.MonitorTarget(
                windowID: effectiveWindowID,
                pid: record.pid,
                targetDisplay: record.sourceYabaiDisp,
                targetSpace: record.sourceSpace,
                targetFrame: record.origFrame,
                traceID: trace
            ))
        }

        let postDisplaySpaces: [String] = (1...displayCount).compactMap { disp -> String? in
            guard let vis = spaceController.displayVisibleSpace(displayIndex: .yabai(disp)) else { return nil }
            return "d\(disp)=s\(vis.yabaiIndex ?? 0)"
        }
        let windowActualSpace = spaceController.windowSpaceIndex(windowID: effectiveWindowID)?.yabaiIndex
        let spaceMatch = windowActualSpace == record.sourceSpace
        log("ToggleEngine.restore: finished", level: .info, fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "restoredTo": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))",
            "success": String(restored),
            "postDisplaySpaces": postDisplaySpaces.joined(separator: ","),
            "windowActualSpace": String(describing: windowActualSpace),
            "targetSourceSpace": String(record.sourceSpace),
            "spaceMatch": String(spaceMatch)
        ])

        if let finalFrame = wm.frame(of: windowAX) {
            log("[ToggleEngine] restore: final frame", fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "finalFrame": QuartzRect(finalFrame).description,
                "onMainScreen": String(CoordinateKit.isOnMainScreen(finalFrame))
            ])
        }

        // restore 成功后自动清除 toggle record — 调用者无需手动 clear
        if restored {
            clear(windowID: record.windowID)
            log("[ToggleEngine] restore: auto-cleared toggle record", fields: [
                "traceID": trace,
                "recordWindowID": String(record.windowID)
            ])
        }
        return restored
    }

    // MARK: - Accidental Switch Detection

    /// 检测并修复 CGEvent 意外切换非目标 display 的问题
    private func fixAccidentalDisplaySwitches(
        preRestoreDisplaySpaces: [Int: Int],
        intentionallySwitchedDisplays: Set<Int>,
        traceID: String
    ) {
        let spaceController = SpaceController.shared
        var accidentalSwitches: [String] = []

        for (disp, preVis) in preRestoreDisplaySpaces {
            if intentionallySwitchedDisplays.contains(disp) { continue }
            let currentVis = spaceController.displayVisibleSpace(displayIndex: .yabai(disp))
            if let cur = currentVis, cur.yabaiIndex != preVis {
                accidentalSwitches.append("d\(disp):s\(preVis)->s\(cur.yabaiIndex ?? 0)")
                log("[ToggleEngine] restore: display \(disp) was accidentally switched from space \(preVis) to \(cur.yabaiIndex ?? 0), fixing", level: .warn, fields: [
                    "traceID": traceID,
                    "display": String(disp),
                    "preRestoreSpace": String(preVis),
                    "currentSpace": String(cur.yabaiIndex ?? 0),
                    "intentionallySwitchedDisplays": intentionallySwitchedDisplays.sorted().map { "d\($0)" }.joined(separator: ",")
                ])
                _ = spaceController.switchDisplayToSpace(
                    targetSpace: .yabai(preVis),
                    operationID: traceID
                )
            }
        }

        if accidentalSwitches.isEmpty {
            log("[ToggleEngine] restore: no accidental display switches detected", level: .debug, fields: [
                "traceID": traceID,
                "intentionallySwitchedDisplays": intentionallySwitchedDisplays.sorted().map { "d\($0)" }.joined(separator: ",")
            ])
        } else {
            log("[ToggleEngine] restore: fixed accidental switches", fields: [
                "traceID": traceID,
                "accidentalSwitches": accidentalSwitches.joined(separator: ",")
            ])
        }
    }

    // MARK: - Cross-Display Restore

    /// 跨显示器 restore：切目标 display 到目标 space → AX apply → 验证 post-move 位置
    private func performCrossDisplayRestore(
        record: ToggleRecord,
        windowAX: AXUIElement,
        effectiveWindowID: UInt32,
        triggerSource: String,
        traceID: String,
        intentionallySwitchedDisplays: inout Set<Int>
    ) -> Bool {
        let wm = WindowManager.shared
        let spaceController = SpaceController.shared

        let targetDisplay = record.sourceYabaiDisp
        let targetSpace = record.sourceSpace
        let displayCurrentSpace = spaceController.displayVisibleSpace(displayIndex: .yabai(targetDisplay))

        log("[ToggleEngine] restore: pre-apply space switch", fields: [
            "traceID": traceID,
            "windowID": String(effectiveWindowID),
            "targetDisplay": String(describing: targetDisplay),
            "targetSpace": String(targetSpace),
            "displayCurrentSpace": String(describing: displayCurrentSpace)
        ])

        if let current = displayCurrentSpace, current.yabaiIndex != targetSpace {
            let switched = performSpaceSwitch(
                targetDisplay: targetDisplay,
                targetSpace: targetSpace,
                traceID: traceID,
                intentionallySwitchedDisplays: &intentionallySwitchedDisplays
            )

            if switched {
                usleep(150_000)
            } else {
                let visibleSpace = spaceController.displayVisibleSpace(displayIndex: .yabai(targetDisplay))
                log("[ToggleEngine] restore: target space switch failed, falling back to visible space", level: .warn, fields: [
                    "traceID": traceID,
                    "targetSpace": String(targetSpace),
                    "visibleSpace": String(describing: visibleSpace?.yabaiIndex),
                    "targetDisplay": String(targetDisplay)
                ])
                if let vis = visibleSpace, vis.yabaiIndex != current.yabaiIndex {
                    _ = performSpaceSwitch(
                        targetDisplay: targetDisplay,
                        targetSpace: vis.yabaiIndex ?? targetSpace,
                        traceID: traceID,
                        intentionallySwitchedDisplays: &intentionallySwitchedDisplays
                    )
                    usleep(100_000)
                }
            }
            log("[ToggleEngine] restore: display switched to target space", fields: [
                "traceID": traceID,
                "targetSpace": String(targetSpace),
                "intentionallySwitchedDisplays": intentionallySwitchedDisplays.sorted().map { "d\($0)" }.joined(separator: ",")
            ])
        }

        // AX apply
        var restored = wm.apply(frame: record.origFrame, to: windowAX, operationID: traceID, stage: "restore_orig")

        if restored {
            if let postFrame = wm.frame(of: windowAX) {
                let onExpectedScreen: Bool
                if record.sourceYabaiDisp == 1 {
                    onExpectedScreen = CoordinateKit.isOnMainScreen(postFrame)
                } else {
                    onExpectedScreen = !CoordinateKit.isOnMainScreen(postFrame)
                }
                if !onExpectedScreen {
                    log("[ToggleEngine] restore: AX apply succeeded but window on WRONG screen, marking as failed", level: .warn, fields: [
                        "traceID": traceID,
                        "windowID": String(effectiveWindowID),
                        "postFrame": "\(postFrame)",
                        "expectedDisplay": String(record.sourceYabaiDisp)
                    ])
                    restored = false
                } else {
                    log("[ToggleEngine] restore: AX apply moved window to correct screen", fields: [
                        "traceID": traceID,
                        "windowID": String(effectiveWindowID),
                        "origFrame": "\(record.origFrame)"
                    ])
                }
            }
        }

        if !restored {
            log("ToggleEngine.restore: AX apply failed, no fallback available", level: .error, fields: [
                "traceID": traceID,
                "windowID": String(effectiveWindowID)
            ])
            return false
        }

        // Post-move verification
        let postMoveAX = wm.findWindowByPID(record.pid, windowID: effectiveWindowID) ?? windowAX
        let postMoveWindowID = wm.windowHandle(for: postMoveAX) ?? effectiveWindowID

        if postMoveWindowID != effectiveWindowID {
            log("[ToggleEngine] restore: CGWindowNumber changed after cross-display move", level: .info, fields: [
                "traceID": traceID,
                "beforeCrossMoveID": String(effectiveWindowID),
                "afterCrossMoveID": String(postMoveWindowID)
            ])
        }

        spaceController.setWindowFloat(postMoveWindowID, operationID: traceID)

        if let actualSpace = spaceController.windowSpaceIndex(windowID: postMoveWindowID)?.yabaiIndex,
           actualSpace != record.sourceSpace {
            log("[ToggleEngine] restore: window on wrong space after AX apply, starting space correction", level: .warn, fields: [
                "traceID": traceID,
                "effectiveWindowID": String(postMoveWindowID),
                "actualSpace": String(actualSpace),
                "targetSpace": String(record.sourceSpace)
            ])

            // 尝试 1: 直接 moveWindow (yabai + NativeSpaceBridge)
            if spaceController.moveWindow(postMoveWindowID, toSpace: .yabai(record.sourceSpace), focus: false, operationID: traceID) {
                usleep(100_000)
                spaceController.setWindowFloat(postMoveWindowID, operationID: traceID)
                if spaceController.windowSpaceIndex(windowID: postMoveWindowID)?.yabaiIndex == record.sourceSpace {
                    log("[ToggleEngine] restore: moveWindow correction succeeded", fields: [
                        "traceID": traceID, "windowID": String(postMoveWindowID), "targetSpace": String(record.sourceSpace)
                    ])
                } else {
                    log("[ToggleEngine] restore: moveWindow reported success but window still on wrong space", level: .warn, fields: [
                        "traceID": traceID, "windowID": String(postMoveWindowID)
                    ])
                }
            }

            // 验证是否修正成功
            let correctedSpace = spaceController.windowSpaceIndex(windowID: postMoveWindowID)?.yabaiIndex
            if correctedSpace == record.sourceSpace {
                // 成功
            } else {
                // 尝试 2: 切换到目标 space 再移动
                log("[ToggleEngine] restore: trying switchDisplayToSpace + moveWindow combo", level: .warn, fields: [
                    "traceID": traceID,
                    "targetSpace": String(record.sourceSpace),
                    "currentSpace": String(describing: correctedSpace)
                ])
                _ = spaceController.switchDisplayToSpace(targetSpace: .yabai(record.sourceSpace), operationID: traceID)
                usleep(100_000)
                _ = spaceController.moveWindow(postMoveWindowID, toSpace: .yabai(record.sourceSpace), focus: false, operationID: traceID)
                usleep(100_000)
                spaceController.setWindowFloat(postMoveWindowID, operationID: traceID)
            }

            // 最终验证
            let finalSpace = spaceController.windowSpaceIndex(windowID: postMoveWindowID)?.yabaiIndex
            if let final = finalSpace, final != record.sourceSpace {
                log("[ToggleEngine] restore: all space corrections failed, switching display to actual space for visibility", level: .warn, fields: [
                    "traceID": traceID,
                    "effectiveWindowID": String(postMoveWindowID),
                    "actualSpace": String(final),
                    "targetSpace": String(record.sourceSpace)
                ])
                let switched = spaceController.switchDisplayToSpace(targetSpace: .yabai(final), operationID: traceID)
                log("[ToggleEngine] restore: display switch to actual space result", fields: [
                    "traceID": traceID,
                    "switched": String(switched),
                    "actualSpace": String(final)
                ])
            }
        }

        return true
    }

    // MARK: - Space Switch Helper

    /// 封装空间切换 + 轮询等待 + display 追踪的通用逻辑
    /// 被 restore() 和 switchToOriginalSpace() 共用
    private func performSpaceSwitch(
        targetDisplay: Int,
        targetSpace: Int,
        traceID: String,
        intentionallySwitchedDisplays: inout Set<Int>
    ) -> Bool {
        let spaceController = SpaceController.shared

        // 1. 记录切换前的 display states
        var preSwitchSpaces: [Int: Int] = [:]
        for d in 1...displayCount {
            if let v = spaceController.displayVisibleSpace(displayIndex: .yabai(d))?.yabaiIndex {
                preSwitchSpaces[d] = v
            }
        }

        // 2. 执行切换
        let switched = spaceController.switchDisplayToSpace(
            targetSpace: .yabai(targetSpace),
            operationID: traceID
        )

        guard switched else { return false }

        // 3. 追踪被 switchDisplayToSpace 影响的所有 display
        for d in 1...displayCount {
            let postVis = spaceController.displayVisibleSpace(displayIndex: .yabai(d))?.yabaiIndex
            if let pre = preSwitchSpaces[d], let post = postVis, pre != post {
                intentionallySwitchedDisplays.insert(d)
                log("[ToggleEngine] display \(d) intentionally switched \(pre)->\(post)", level: .debug, fields: [
                    "traceID": traceID,
                    "display": String(d),
                    "from": String(pre),
                    "to": String(post)
                ])
            }
        }

        // 4. 轮询等待目标 display 到达目标 space
        let started = Date()
        var pollCount = 0
        while Date().timeIntervalSince(started) < 0.4 {
            if spaceController.displayVisibleSpace(displayIndex: .yabai(targetDisplay))?.yabaiIndex == targetSpace { break }
            usleep(30_000)
            pollCount += 1
        }
        let finalSpace = spaceController.displayVisibleSpace(displayIndex: .yabai(targetDisplay))?.yabaiIndex
        log("[ToggleEngine] space poll completed", level: .debug, fields: [
            "traceID": traceID,
            "targetDisplay": String(targetDisplay),
            "targetSpace": String(targetSpace),
            "finalSpace": String(describing: finalSpace),
            "pollCount": String(pollCount),
            "reachedTarget": String(finalSpace == targetSpace)
        ])

        return true
    }

    // MARK: - Space Switching

    /// 切换到窗口的原始 space
    /// effectiveWindowID: 跨显示器移动后可能变化的 CGWindowNumber，用于 yabai 命令
    private func switchToOriginalSpace(record: ToggleRecord, windowAX: AXUIElement, effectiveWindowID: UInt32, triggerSource: String, traceID: String, intentionallySwitchedDisplays: inout Set<Int>) {
        let spaceController = SpaceController.shared
        let targetSpace = record.sourceSpace
        let targetDisplay = record.sourceYabaiDisp

        // 查询目标 display 当前显示的 space（不是窗口所在的 space）
        let displayCurrentSpace = spaceController.displayVisibleSpace(displayIndex: .yabai(targetDisplay))

        log("ToggleEngine.switchToOriginalSpace: space check", fields: [
            "traceID": traceID,
            "targetSpace": String(targetSpace),
            "targetDisplay": String(describing: targetDisplay),
            "displayCurrentSpace": String(describing: displayCurrentSpace),
            "effectiveWindowID": String(effectiveWindowID),
            "triggerSource": triggerSource
        ])

        if let current = displayCurrentSpace, current.yabaiIndex == targetSpace {
            log("ToggleEngine.switchToOriginalSpace: target display already on correct space, skipping switch", fields: [
                "traceID": traceID,
                "space": String(targetSpace)
            ])
            // display 已经在正确 space，只需移动窗口到该 space
            let earlyMoved = spaceController.moveWindow(
                effectiveWindowID,
                toSpace: .yabai(targetSpace),
                focus: false,
                operationID: traceID
            )
            if earlyMoved {
                usleep(100_000)
                spaceController.setWindowFloat(effectiveWindowID, operationID: traceID)
            }
            return
        }

        log("ToggleEngine.switchToOriginalSpace: need space switch", fields: [
            "traceID": traceID,
            "displayCurrentSpace": String(describing: displayCurrentSpace?.yabaiIndex),
            "targetSpace": String(targetSpace),
            "targetDisplay": String(describing: targetDisplay),
            "sourceYabaiDisp": String(record.sourceYabaiDisp),
            "effectiveWindowID": String(effectiveWindowID)
        ])

        // 目标 display 不在正确 space — 需要先切换 display 的 space 再移动窗口
        if displayCurrentSpace?.yabaiIndex != targetSpace {
            let switchStart = Date()
            let switched = performSpaceSwitch(
                targetDisplay: targetDisplay,
                targetSpace: targetSpace,
                traceID: traceID,
                intentionallySwitchedDisplays: &intentionallySwitchedDisplays
            )
            log("ToggleEngine.switchToOriginalSpace: switchDisplayToSpace result", fields: [
                "traceID": traceID,
                "switched": String(switched),
                "targetSpace": String(targetSpace),
                "switchDisplayMs": String(elapsedMilliseconds(since: switchStart))
            ])
        }

        // 移动窗口到目标 space（使用 effectiveWindowID，可能是跨显示器移动后的新 ID）
        let moveStart = Date()
        let moved = spaceController.moveWindow(
            effectiveWindowID,
            toSpace: .yabai(targetSpace),
            focus: triggerSource == "carbon_hotkey",
            operationID: traceID
        )
        log("ToggleEngine.switchToOriginalSpace: moveWindow result", fields: [
            "traceID": traceID,
            "moved": String(moved),
            "moveWindowMs": String(elapsedMilliseconds(since: moveStart)),
            "effectiveWindowID": String(effectiveWindowID),
            "targetSpace": String(targetSpace)
        ])

        if moved {
            // 窗口已到达目标 space — 在目标 space 上设 float，防止 yabai 重新 tile
            usleep(100_000)
            spaceController.setWindowFloat(effectiveWindowID, operationID: traceID)

            // 快速验证窗口已在目标 space
            let started = Date()
            var verified = false
            while Date().timeIntervalSince(started) < 0.2 {
                if let s = spaceController.windowSpaceIndex(windowID: effectiveWindowID)?.yabaiIndex, s == targetSpace {
                    verified = true
                    break
                }
                usleep(20_000)
            }
            log("ToggleEngine.switchToOriginalSpace: window space verification", level: .debug, fields: [
                "traceID": traceID,
                "effectiveWindowID": String(effectiveWindowID),
                "targetSpace": String(targetSpace),
                "verified": String(verified)
            ])
        } else {
            log("ToggleEngine.switchToOriginalSpace: moveWindow failed, window is on correct display but may be on wrong space", level: .warn, fields: [
                "traceID": traceID,
                "effectiveWindowID": String(effectiveWindowID),
                "targetSpace": String(targetSpace)
            ])
        }
    }
}
