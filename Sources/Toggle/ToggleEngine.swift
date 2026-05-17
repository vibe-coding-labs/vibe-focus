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

    // MARK: - Clear (Restore 后或窗口关闭时)

    /// 清除 toggle state
    func clear(windowID: UInt32) {
        store.clearToggleRecord(windowID: windowID)
        log("ToggleEngine.clear", fields: ["windowID": String(windowID)])
    }

    // MARK: - Restore 执行

    /// 执行恢复：移动窗口回原始位置 + 切换到原始 space
    @discardableResult
    func restore(windowID: UInt32, triggerSource: String, traceID: String? = nil) -> Bool {
        let trace = traceID ?? makeOperationID(prefix: "te")
        guard let record = load(windowID: windowID) else {
            log("ToggleEngine.restore: no toggle record found", level: .warn, fields: [
                "traceID": trace,
                "windowID": String(windowID)
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

        log("[ToggleEngine] restore: coordinate context", fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "origFrame": QuartzRect(record.origFrame).description,
            "sourceYabaiDisp": String(record.sourceYabaiDisp),
            "sourceSpace": String(record.sourceSpace),
            "mainScreenFrame": CoordinateKit.mainScreenQuartzFrame.map { "\($0)" } ?? "nil",
            "currentScreens": NSScreen.screens.map { "\($0.frame)" }.joined(separator: " | ")
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

        // 1. 找到窗口 AX element
        guard let windowAX = wm.findWindowByPID(record.pid, windowID: record.windowID) else {
            log("ToggleEngine.restore: window AX element not found", level: .warn, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "pid": String(record.pid)
            ])
            return false
        }

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

        // 3. 先将窗口设为浮动状态（必须在 space 切换之前！）
        // 如果先切 space 再设浮动，yabai 会在 space 切换瞬间立刻 tile 窗口，改变尺寸
        spaceController.setWindowFloat(record.windowID, operationID: trace)

        // 4. 切换到原始 space
        switchToOriginalSpace(record: record, windowAX: windowAX, triggerSource: triggerSource, traceID: trace)

        // 5. 切换完成后重新获取 AX element（space 切换可能使旧引用失效）
        let restoreAX = wm.findWindowByPID(record.pid, windowID: record.windowID) ?? windowAX

        // 5.5 恢复窗口到原始位置
        // 策略：先尝试 AX 直接 apply origFrame（macOS 会自动处理跨显示器移动）
        // 仅在 AX 坐标被钳制时才回退到 CGEvent 拖拽
        var restored = false

        restored = wm.apply(frame: record.origFrame, to: restoreAX, operationID: trace, stage: "restore_orig")

        if restored {
            // 验证窗口确实在目标屏幕上（AX apply 可能因坐标钳制返回 true 但窗口在错误屏幕）
            if let postFrame = wm.frame(of: restoreAX) {
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
                    log("[ToggleEngine] restore: direct AX apply succeeded with correct screen", fields: [
                        "traceID": trace,
                        "windowID": String(windowID),
                        "origFrame": "\(record.origFrame)"
                    ])
                }
            }
        }

        if !restored {
            // AX apply 失败（坐标被钳制） — 回退到 CGEvent 拖拽
            let mainScreenFrame = NSScreen.screens.first { $0.frame.origin == .zero }?.frame ?? .zero
            let currentFrame = wm.frame(of: restoreAX)
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
                        let postDragAX = wm.findWindowByPID(record.pid, windowID: record.windowID) ?? restoreAX
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

        log("ToggleEngine.restore: finished", level: .info, fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "restoredTo": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))",
            "success": String(restored)
        ])

        if let finalFrame = wm.frame(of: restoreAX) {
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
    /// 核心逻辑：查询目标 display 当前可见 space，如果已经是目标 space 则跳过切换
    private func switchToOriginalSpace(record: ToggleRecord, windowAX: AXUIElement, triggerSource: String, traceID: String) {
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
            "triggerSource": triggerSource
        ])

        if let current = displayCurrentSpace, current == targetSpace {
            log("ToggleEngine.switchToOriginalSpace: target display already on correct space, skipping switch", fields: [
                "traceID": traceID,
                "space": String(targetSpace)
            ])
            // display 已经在正确 space，只需移动窗口到该 space
            _ = spaceController.moveWindow(
                record.windowID,
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
            "sourceYabaiDisp": String(record.sourceYabaiDisp)
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

        // 移动窗口到目标 space
        let moveStart = Date()
        let moved = spaceController.moveWindow(
            record.windowID,
            toSpaceIndex: targetSpace,
            focus: triggerSource == "carbon_hotkey",
            operationID: traceID
        )
        log("ToggleEngine.switchToOriginalSpace: moveWindow result", fields: [
            "traceID": traceID,
            "moved": String(moved),
            "moveWindowMs": String(elapsedMilliseconds(since: moveStart))
        ])

        if moved {
            // 快速验证窗口已在目标 space（替代固定 200ms）
            let started = Date()
            while Date().timeIntervalSince(started) < 0.2 {
                if let s = spaceController.windowSpaceIndex(windowID: record.windowID), s == targetSpace { break }
                usleep(20_000)
            }
        } else {
            log("ToggleEngine.switchToOriginalSpace: moveWindow also failed after display switch", level: .warn, fields: [
                "traceID": traceID,
                "windowID": String(record.windowID),
                "targetSpace": String(targetSpace)
            ])
        }
    }
}
