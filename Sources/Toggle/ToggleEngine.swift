import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

/// Toggle Engine — 窗口 toggle/restore 的单一入口
///
/// 设计原则：
/// 1. 单一事实来源：所有 toggle state 只存 SQLite `windows` 表，不缓存到内存
/// 2. 确定性查找：用 windowID 直接查 SQLite，不走 PID/TTY/PPID 猜测链
/// 3. 原子操作：save 是一次 SQLite UPDATE，read 是一次 SELECT
@MainActor
final class ToggleEngine {

    static let shared = ToggleEngine()
    private init() {}

    private var store: WindowStateStore { WindowStateStore.shared }

    // MARK: - Save (Ctrl+Q 触发)

    /// 保存 toggle 快照 — 在 moveWindowToMainScreen 成功后调用
    func save(
        windowID: UInt32,
        pid: Int32,
        bundleIdentifier: String?,
        appName: String?,
        origFrame: CGRect,
        sourceSpace: Int,
        sourceDisplay: Int,
        sourceYabaiDisp: Int,
        sourceDispSpace: Int,
        targetFrame: CGRect,
        targetDisplay: Int,
        sessionID: String?
    ) {
        // 验证 origFrame 不在主屏上 — 如果 origFrame 在主屏，说明数据异常
        let mainScreen = NSScreen.screens.first { $0.frame.origin == .zero }
        if let mainScreenFrame = mainScreen?.frame {
            let origCenter = CGPoint(x: origFrame.midX, y: origFrame.midY)
            if mainScreenFrame.contains(origCenter) {
                log(
                    "[ToggleEngine] save rejected: origFrame is on main screen (corrupted data)",
                    level: .warn,
                    fields: [
                        "windowID": String(windowID),
                        "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
                        "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.size.width))x\(Int(targetFrame.size.height))",
                        "sourceSpace": String(describing: sourceSpace),
                        "sourceYabaiDisp": String(describing: sourceYabaiDisp)
                    ]
                )
                return
            }
        }

        let record = ToggleRecord(
            windowID: windowID,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            origFrame: origFrame,
            sourceSpace: sourceSpace,
            sourceDisplay: sourceDisplay,
            sourceYabaiDisp: sourceYabaiDisp,
            sourceDispSpace: sourceDispSpace,
            targetFrame: targetFrame,
            targetDisplay: targetDisplay,
            toggledAt: Date(),
            sessionID: sessionID
        )

        store.saveToggleRecord(record)

        log("ToggleEngine.save", level: .info, fields: [
            "windowID": String(windowID),
            "sourceSpace": String(sourceSpace),
            "sourceDisplay": String(sourceDisplay),
            "sourceYabaiDisp": String(sourceYabaiDisp),
            "sourceDispSpace": String(sourceDispSpace),
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
            "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.size.width))x\(Int(targetFrame.size.height))"
        ])
    }

    // MARK: - Load (UserPromptSubmit 触发)

    /// 按 windowID 读取 toggle record
    func load(windowID: UInt32) -> ToggleRecord? {
        return store.loadToggleRecord(windowID: windowID)
    }

    /// 按 PID 读取最近的 toggle record（CGWindowNumber 变化时的 fallback）
    func loadByPID(pid: Int32) -> ToggleRecord? {
        return store.loadToggleRecordByPID(pid: pid)
    }

    // MARK: - Clear (Restore 后或窗口关闭时)

    /// 清除 toggle state
    func clear(windowID: UInt32) {
        store.clearToggleRecord(windowID: windowID)
        log("ToggleEngine.clear", fields: ["windowID": String(windowID)])
    }

    /// 按 PID 清除 toggle state（PID fallback 场景）
    func clearByPID(pid: Int32) {
        if let record = loadByPID(pid: pid) {
            store.clearToggleRecord(windowID: record.windowID)
            log("ToggleEngine.clearByPID", fields: ["pid": String(pid), "windowID": String(record.windowID)])
        }
    }

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
        // origFrame 是 Quartz 坐标，NSScreen.frame 是 Cocoa 坐标，需要转换后再比较
        let origCenter = CGPoint(x: record.origFrame.midX, y: record.origFrame.midY)
        let mainScreenHeight = NSScreen.screens[0].frame.height
        let onAnyScreen = NSScreen.screens.contains { screen in
            let sf = screen.frame
            let quartzFrame = CGRect(
                x: sf.origin.x,
                y: mainScreenHeight - sf.origin.y - sf.height,
                width: sf.width,
                height: sf.height
            )
            return quartzFrame.insetBy(dx: -200, dy: -200).contains(origCenter)
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

        // 3. 先将窗口设为浮动状态（必须在任何移动之前！）
        // yabai 会在窗口到达新 space 的瞬间 tile 窗口，改变尺寸
        spaceController.setWindowFloat(effectiveWindowID, operationID: trace)

        // 3.5 记录所有 display 当前可见 space（用于 restore 后检测意外切换）
        var preRestoreDisplaySpaces: [Int: Int] = [:]
        for disp in 1...3 {
            if let vis = spaceController.displayVisibleSpace(displayIndex: disp) {
                preRestoreDisplaySpaces[disp] = vis
            }
        }

        // 4. 跨显示器 restore：先切目标 display 到目标 space，再 AX apply
        // 关键顺序：先 switchDisplayToSpace → 再 apply(frame)
        // 原因：AX apply 把窗口移到目标显示器时，窗口会出现在当前可见 space 上
        // 如果先 apply 再切 space，窗口会落在错误的 space 上并被隐藏，yabai 无法移动隐藏窗口
        var restored = false
        let needCrossDisplayMove = record.sourceYabaiDisp != 1

        if needCrossDisplayMove {
            // 4a. 先切换目标 display 到原始 space
            let targetDisplay = record.sourceYabaiDisp
            let targetSpace = record.sourceSpace
            let displayCurrentSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)

            log("[ToggleEngine] restore: pre-apply space switch", fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "targetDisplay": String(describing: targetDisplay),
                "targetSpace": String(targetSpace),
                "displayCurrentSpace": String(describing: displayCurrentSpace)
            ])

            if let current = displayCurrentSpace, current != targetSpace {
                let switched = spaceController.switchDisplayToSpace(
                    targetSpace: targetSpace,
                    operationID: trace
                )
                if switched {
                    let td = targetDisplay
                    let started = Date()
                    while Date().timeIntervalSince(started) < 0.4 {
                        if spaceController.displayVisibleSpace(displayIndex: td) == targetSpace { break }
                        usleep(30_000)
                    }
                    // macOS space switch 动画需要额外时间才能完全提交
                    // 过早 AX apply 会被 macOS 覆盖，把窗口放到错误 space
                    usleep(150_000)
                }
                log("[ToggleEngine] restore: display switched to target space", fields: [
                    "traceID": trace,
                    "switched": String(switched),
                    "targetSpace": String(targetSpace)
                ])
            }
        }

        // 4b. AX apply — 窗口到达目标显示器时，会出现在已切换好的正确 space 上
        restored = wm.apply(frame: record.origFrame, to: windowAX, operationID: trace, stage: "restore_orig")

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
                        "traceID": trace,
                        "windowID": String(windowID),
                        "postFrame": "\(postFrame)",
                        "expectedDisplay": String(record.sourceYabaiDisp)
                    ])
                    restored = false
                } else {
                    log("[ToggleEngine] restore: AX apply moved window to correct screen", fields: [
                        "traceID": trace,
                        "windowID": String(windowID),
                        "origFrame": "\(record.origFrame)"
                    ])
                }
            }
        }

        if !restored {
            // AX apply 失败（坐标被钳制到主屏） — 回退到 CGEvent 拖拽
            let mainScreenFrame = NSScreen.screens.first { $0.frame.origin == .zero }?.frame ?? .zero
            let currentFrame = wm.frame(of: windowAX)
            let windowOnMain = currentFrame.map { mainScreenFrame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false

            if windowOnMain && !mainScreenFrame.contains(origCenter) {
                let targetScreen = NSScreen.screens.first { $0.frame.origin != .zero }
                if let screen = targetScreen {
                    log(
                        "[ToggleEngine] restore: AX apply clamped, trying CGEvent drag fallback",
                        level: .info,
                        fields: [
                            "traceID": trace,
                            "windowID": String(windowID),
                            "currentFrame": currentFrame.map { "\($0)" } ?? "nil",
                            "targetScreen": "\(screen.frame)",
                            "origFrame": "\(record.origFrame)"
                        ]
                    )

                    if let app = NSRunningApplication(processIdentifier: pid_t(record.pid)) {
                        app.activate(options: .activateIgnoringOtherApps)
                        usleep(50_000)
                    }

                    let dragFrame = currentFrame ?? record.origFrame
                    let dragSucceeded = NativeSpaceBridge.dragWindowToDisplay(
                        windowFrame: dragFrame,
                        targetScreen: screen,
                        operationID: trace
                    )

                    if dragSucceeded {
                        usleep(150_000)
                        let postDragAX = wm.findWindowByPID(record.pid, windowID: effectiveWindowID) ?? windowAX
                        restored = wm.apply(frame: record.origFrame, to: postDragAX, operationID: trace, stage: "restore_orig_after_drag")
                    }
                }
            }

            if !restored {
                log("ToggleEngine.restore: all restore strategies failed", level: .error, fields: [
                    "traceID": trace,
                    "windowID": String(windowID)
                ])
            }
        }

        // 5. 窗口已到达目标显示器的正确 space → 重新获取 CGWindowNumber + 重新设置 float
        // 跨显示器移动后 iTerm2 等应用可能改变 CGWindowNumber
        if needCrossDisplayMove, restored {
            let postMoveAX = wm.findWindowByPID(record.pid, windowID: effectiveWindowID) ?? windowAX
            let postMoveWindowID = wm.windowHandle(for: postMoveAX) ?? effectiveWindowID

            if postMoveWindowID != effectiveWindowID {
                log("[ToggleEngine] restore: CGWindowNumber changed after cross-display move", level: .info, fields: [
                    "traceID": trace,
                    "windowID": String(windowID),
                    "beforeCrossMoveID": String(effectiveWindowID),
                    "afterCrossMoveID": String(postMoveWindowID)
                ])
            }

            // 重新设置浮动 + 验证 space 位置
            spaceController.setWindowFloat(postMoveWindowID, operationID: trace)

            // 验证窗口确实在目标 space（如果不在，尝试修复）
            if let actualSpace = spaceController.windowSpaceIndex(windowID: postMoveWindowID),
               actualSpace != record.sourceSpace {
                log("[ToggleEngine] restore: window on wrong space after AX apply, trying moveWindow fallback", level: .warn, fields: [
                    "traceID": trace,
                    "effectiveWindowID": String(postMoveWindowID),
                    "actualSpace": String(actualSpace),
                    "targetSpace": String(record.sourceSpace)
                ])
                let moved = spaceController.moveWindow(
                    postMoveWindowID,
                    toSpaceIndex: record.sourceSpace,
                    focus: triggerSource == "carbon_hotkey",
                    operationID: trace
                )

                if !moved {
                    // moveWindow 失败（yabai scripting addition 通常损坏） — 切换 display 到窗口实际 space
                    // 不能让窗口留在非可见 space 上完全不可见
                    log("[ToggleEngine] restore: moveWindow failed, switching display to window's actual space for visibility", level: .warn, fields: [
                        "traceID": trace,
                        "effectiveWindowID": String(postMoveWindowID),
                        "actualSpace": String(actualSpace),
                        "targetSpace": String(record.sourceSpace),
                        "note": "window at correct position but on different space than original"
                    ])
                    let switched = spaceController.switchDisplayToSpace(
                        targetSpace: actualSpace,
                        operationID: trace
                    )
                    log("[ToggleEngine] restore: display switch to actual space result", fields: [
                        "traceID": trace,
                        "switched": String(switched),
                        "actualSpace": String(actualSpace)
                    ])
                }
            }
        } else if restored {
            // 主屏到主屏的 restore，只需切换 space
            switchToOriginalSpace(
                record: record,
                windowAX: windowAX,
                effectiveWindowID: effectiveWindowID,
                triggerSource: triggerSource,
                traceID: trace
            )
        }

        // 6. 检测并修复 CGEvent 意外切换其他 display 的问题
        // CGEvent Ctrl+Arrow 可能影响非目标 display 的 space
        if restored, !preRestoreDisplaySpaces.isEmpty {
            let intentionallySwitchedDisplay = record.sourceYabaiDisp
            for (disp, preVis) in preRestoreDisplaySpaces {
                if disp == intentionallySwitchedDisplay { continue }
                let currentVis = spaceController.displayVisibleSpace(displayIndex: disp)
                if let cur = currentVis, cur != preVis {
                    log("[ToggleEngine] restore: display \(disp) was accidentally switched from space \(preVis) to \(cur), fixing", level: .warn, fields: [
                        "traceID": trace,
                        "display": String(disp),
                        "preRestoreSpace": String(preVis),
                        "currentSpace": String(cur)
                    ])
                    _ = spaceController.switchDisplayToSpace(
                        targetSpace: preVis,
                        operationID: trace
                    )
                }
            }
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

        log("ToggleEngine.restore: finished", level: .info, fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "restoredTo": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))",
            "success": String(restored)
        ])

        if let finalFrame = wm.frame(of: windowAX) {
            log("[ToggleEngine] restore: final frame", fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "finalFrame": QuartzRect(finalFrame).description,
                "onMainScreen": String(CoordinateKit.isOnMainScreen(finalFrame))
            ])
        }
        return restored
    }

    // MARK: - Space Switching

    /// 切换到窗口的原始 space
    /// effectiveWindowID: 跨显示器移动后可能变化的 CGWindowNumber，用于 yabai 命令
    private func switchToOriginalSpace(record: ToggleRecord, windowAX: AXUIElement, effectiveWindowID: UInt32, triggerSource: String, traceID: String) {
        let spaceController = SpaceController.shared
        let targetSpace = record.sourceSpace
        let targetDisplay = record.sourceYabaiDisp

        // 查询目标 display 当前显示的 space（不是窗口所在的 space）
        let displayCurrentSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)

        log("ToggleEngine.switchToOriginalSpace: space check", fields: [
            "traceID": traceID,
            "targetSpace": String(targetSpace),
            "targetDisplay": String(describing: targetDisplay),
            "displayCurrentSpace": String(describing: displayCurrentSpace),
            "effectiveWindowID": String(effectiveWindowID),
            "triggerSource": triggerSource
        ])

        if let current = displayCurrentSpace, current == targetSpace {
            log("ToggleEngine.switchToOriginalSpace: target display already on correct space, skipping switch", fields: [
                "traceID": traceID,
                "space": String(targetSpace)
            ])
            // display 已经在正确 space，只需移动窗口到该 space
            _ = spaceController.moveWindow(
                effectiveWindowID,
                toSpaceIndex: targetSpace,
                focus: false,
                operationID: traceID
            )
            return
        }

        log("ToggleEngine.switchToOriginalSpace: need space switch", fields: [
            "traceID": traceID,
            "displayCurrentSpace": String(describing: displayCurrentSpace),
            "targetSpace": String(targetSpace),
            "targetDisplay": String(describing: targetDisplay),
            "sourceYabaiDisp": String(record.sourceYabaiDisp),
            "effectiveWindowID": String(effectiveWindowID)
        ])

        // 目标 display 不在正确 space — 需要先切换 display 的 space 再移动窗口
        if let current = displayCurrentSpace, current != targetSpace {
            let switchStart = Date()
            let switched = spaceController.switchDisplayToSpace(
                targetSpace: targetSpace,
                operationID: traceID
            )
            log("ToggleEngine.switchToOriginalSpace: switchDisplayToSpace result", fields: [
                "traceID": traceID,
                "switched": String(switched),
                "targetSpace": String(targetSpace),
                "switchDisplayMs": String(elapsedMilliseconds(since: switchStart))
            ])
            if switched {
                // 轮询等待 display 到达目标 space（替代固定 400ms sleep）
                let td = targetDisplay
                let started = Date()
                while Date().timeIntervalSince(started) < 0.4 {
                    if spaceController.displayVisibleSpace(displayIndex: td) == targetSpace { break }
                    usleep(30_000)
                }
            }
        }

        // 移动窗口到目标 space（使用 effectiveWindowID，可能是跨显示器移动后的新 ID）
        let moveStart = Date()
        let moved = spaceController.moveWindow(
            effectiveWindowID,
            toSpaceIndex: targetSpace,
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
            // 快速验证窗口已在目标 space
            let started = Date()
            while Date().timeIntervalSince(started) < 0.2 {
                if let s = spaceController.windowSpaceIndex(windowID: effectiveWindowID), s == targetSpace { break }
                usleep(20_000)
            }
        } else {
            log("ToggleEngine.switchToOriginalSpace: moveWindow failed, window is on correct display but may be on wrong space", level: .warn, fields: [
                "traceID": traceID,
                "effectiveWindowID": String(effectiveWindowID),
                "targetSpace": String(targetSpace)
            ])
        }
    }
}
