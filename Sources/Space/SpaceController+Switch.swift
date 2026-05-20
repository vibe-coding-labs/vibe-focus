import AppKit
import Foundation

@MainActor
extension SpaceController {

    func switchDisplayToSpace(targetSpace: Int, operationID: String?) -> Bool {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            log("[SpaceController] switchDisplayToSpace: not enabled", level: .warn, fields: ["op": op])
            return false
        }

        log("[SpaceController] switchDisplayToSpace", fields: [
            "op": op, "targetSpace": String(targetSpace)
        ])

        // Strategy 1: yabai -m space --focus (需要 SA)
        let yabaiResult = runYabai(
            arguments: ["-m", "space", "--focus", String(targetSpace)],
            operation: "switchDisplayToSpace_yabai",
            operationID: op
        )
        if let result = yabaiResult, result.exitCode == 0 {
            log("[SpaceController] switchDisplayToSpace: yabai succeeded", fields: [
                "op": op, "targetSpace": String(targetSpace)
            ])
            return true
        }

        log("[SpaceController] switchDisplayToSpace: yabai failed, trying CGEvent fallback", level: .info, fields: [
            "op": op, "targetSpace": String(targetSpace)
        ])

        // Strategy 2: CGEvent — 先用 yabai 激活目标 display，再 Ctrl+Left/Right
        let steps = calculateFocusSteps(targetSpaceIndex: targetSpace)
        log("[SpaceController] switchDisplayToSpace: CGEvent steps=\(steps)", fields: [
            "op": op, "targetSpace": String(targetSpace), "steps": String(steps)
        ])

        // 先用 yabai display --focus 激活目标 display（不需要 SA）
        // 确保 CGEvent Ctrl+Arrow 只影响目标 display，不会意外切换其他 display
        if let targetDisplayIdx = querySpaces()?.first(where: { $0.index == targetSpace })?.display {
            let focusResult = runYabai(
                arguments: ["-m", "display", "--focus", String(targetDisplayIdx)],
                operation: "switchDisplayToSpace_display_focus",
                operationID: op
            )
            if let result = focusResult, result.exitCode == 0 {
                log("[SpaceController] switchDisplayToSpace: yabai display focus succeeded", fields: [
                    "op": op, "targetDisplay": String(targetDisplayIdx)
                ])
                usleep(30_000)
            } else {
                log("[SpaceController] switchDisplayToSpace: yabai display focus failed, relying on cursor move", level: .info, fields: [
                    "op": op, "targetDisplay": String(targetDisplayIdx)
                ])
            }
        }

        guard steps != 0 else {
            // 目标 space 已经可见，但可能需要移动活跃 display
            if let (savedCursor, savedApp) = saveAndMoveCursor(toSpace: targetSpace, operationID: op) {
                restoreCursor(savedCursor, savedApp: savedApp)
            }
            return true
        }

        // 移鼠标到目标 display，发送 Ctrl+Left/Right，恢复鼠标
        let saved = saveAndMoveCursor(toSpace: targetSpace, operationID: op)

        let success = NativeSpaceBridge.focusSpace(steps: steps, operationID: op)

        if let (savedCursor, savedApp) = saved {
            restoreCursor(savedCursor, savedApp: savedApp)
        }

        if success {
            usleep(30_000)
            let postSwitchSpace = displayVisibleSpace(displayIndex: querySpaces()?.first(where: { $0.index == targetSpace })?.display)
            log("[SpaceController] switchDisplayToSpace: CGEvent succeeded", fields: [
                "op": op,
                "targetSpace": String(targetSpace),
                "steps": String(steps),
                "postSwitchSpace": String(describing: postSwitchSpace),
                "reachedTarget": String(postSwitchSpace == targetSpace)
            ])
            return true
        }

        log("[SpaceController] switchDisplayToSpace: all strategies failed", level: .error, fields: [
            "op": op, "targetSpace": String(targetSpace)
        ])
        return false
    }

    func focusSpace(_ spaceIndex: Int, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        log(
            "[focusSpace] called",
            level: .debug,
            fields: [
                "op": op,
                "targetSpace": String(spaceIndex)
            ]
        )
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            log(
                "[focusSpace] aborted: not enabled",
                level: .debug,
                fields: ["op": op]
            )
            return false
        }
        guard canControlSpaces else {
            markOperationError("Cannot focus another space because cross-space control is unavailable", operationID: op)
            return false
        }

        // 记录 focusSpace 调用的完整上下文
        let preFocusSpace = queryFocusedSpace()?.index
        log(
            "[focusSpace] current space resolved",
            level: .debug,
            fields: [
                "op": op,
                "preFocusSpace": String(describing: preFocusSpace),
                "targetSpace": String(spaceIndex)
            ]
        )
        let targetDisplay = querySpaces()?.first(where: { $0.index == spaceIndex })?.display
        log(
            "[SpaceController] focusSpace called",
            fields: [
                "op": op,
                "targetSpace": String(spaceIndex),
                "targetDisplay": String(describing: targetDisplay),
                "currentSpace": String(describing: preFocusSpace),
                "canControlSpaces": String(canControlSpaces)
            ]
        )

        let variants = [["-m", "space", "--focus", "\(spaceIndex)"]]
        let result = runYabaiVariants(variants: variants, operation: "focusSpace(\(spaceIndex))", operationID: op)
        log(
            "[focusSpace] yabai runYabaiVariants returned",
            level: .debug,
            fields: [
                "op": op,
                "success": String(result.success),
                "targetSpace": String(spaceIndex)
            ]
        )
        if result.success {
            log(
                "[focusSpace] yabai succeeded",
                level: .debug,
                fields: ["op": op, "targetSpace": String(spaceIndex)]
            )
            return true
        }

        // yabai 失败，使用 CGEvent 键盘事件 fallback
        log(
            "[focusSpace] yabai failed, calculating CGEvent fallback steps",
            level: .debug,
            fields: ["op": op, "targetSpace": String(spaceIndex)]
        )
        let steps = calculateFocusSteps(targetSpaceIndex: spaceIndex)
        log(
            "[focusSpace] calculateFocusSteps returned",
            level: .debug,
            fields: [
                "op": op,
                "steps": String(steps),
                "targetSpace": String(spaceIndex)
            ]
        )
        log(
            "[SpaceController] yabai focusSpace failed, trying CGEvent fallback",
            fields: [
                "op": op,
                "yabaiIndex": String(spaceIndex),
                "targetDisplay": String(describing: targetDisplay),
                "steps": String(steps),
                "hasDisplayCenter": String(displayCenterCG(spaceIndex: spaceIndex) != nil)
            ]
        )

        if steps == 0 {
            // steps=0 表示目标 space 在目标显示器上已经是可见的
            // 但全局焦点可能在另一个显示器上，仍需移动光标以切换活跃显示器
            let currentGlobalSpace = queryFocusedSpace()?.index
            if currentGlobalSpace == spaceIndex {
                log(
                    "[SpaceController] CGEvent fallback skipped: global space matches target",
                    fields: [
                        "op": op,
                        "targetSpace": String(spaceIndex),
                        "currentGlobalSpace": String(describing: currentGlobalSpace)
                    ]
                )
                return true // 全局焦点已在目标 space
            }

            // 全局焦点不在目标 space — 移动光标到目标显示器以切换活跃显示器
            log(
                "[SpaceController] steps=0 but global space differs, moving cursor to target display",
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex),
                    "currentGlobalSpace": String(describing: currentGlobalSpace),
                    "hasDisplayCenter": String(displayCenterCG(spaceIndex: spaceIndex) != nil)
                ]
            )

            let savedFrontApp = NSWorkspace.shared.frontmostApplication

            let savedCursor = NSEvent.mouseLocation
            let mainScreenHeight = NSScreen.screens[0].frame.height
            let savedCursorCG = CGPoint(x: savedCursor.x, y: mainScreenHeight - savedCursor.y)

            if let center = displayCenterCG(spaceIndex: spaceIndex) {
                if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                            mouseCursorPosition: center, mouseButton: .left) {
                    moveEvent.post(tap: .cghidEventTap)
                }
                usleep(50_000)
            }

            // 恢复鼠标位置
            if let restoreEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                           mouseCursorPosition: savedCursorCG, mouseButton: .left) {
                restoreEvent.post(tap: .cghidEventTap)
            }

            usleep(50_000) // 等待显示器切换

            // 恢复前台应用焦点 — CGEvent 鼠标移动会激活副屏上的应用（通常是 Chrome）
            savedFrontApp?.activate(options: .activateIgnoringOtherApps)

            let postSwitchSpace = queryFocusedSpace()?.index
            log(
                "[SpaceController] cursor move completed",
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex),
                    "preSwitchGlobalSpace": String(describing: currentGlobalSpace),
                    "postSwitchGlobalSpace": String(describing: postSwitchSpace),
                    "reachedTarget": String(postSwitchSpace == spaceIndex)
                ]
            )
            return true
        }

        // 关键：Ctrl+Left/Right 只影响鼠标所在显示器的空间
        // 用 CGEvent 发送鼠标移动事件（非 CGWarp，后者不更新系统活跃显示器状态）
        let savedFrontApp = NSWorkspace.shared.frontmostApplication

        let savedCursor = NSEvent.mouseLocation
        let mainScreenHeight = NSScreen.screens[0].frame.height
        let savedCursorCG = CGPoint(x: savedCursor.x, y: mainScreenHeight - savedCursor.y)

        let targetCenterCG = displayCenterCG(spaceIndex: spaceIndex)
        if let center = targetCenterCG {
            // 用 CGEvent 鼠标移动事件（而非 CGWarpMouseCursorPosition）
            // 这样 WindowServer 会真正更新"活跃显示器"状态
            log("[SpaceController] focusSpace: CGEvent cursor move to target display", level: .debug, fields: [
                "op": op,
                "targetCenter": "\(Int(center.x)),\(Int(center.y))"
            ])
            if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                        mouseCursorPosition: center, mouseButton: .left) {
                moveEvent.post(tap: .cghidEventTap)
            }
            usleep(50_000) // 50ms 等系统处理鼠标移动
        } else {
            log(
                "[SpaceController] CGEvent fallback: could not determine display center",
                level: .warn,
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex)
                ]
            )
        }

        let success = NativeSpaceBridge.focusSpace(steps: steps, operationID: op)

        // 恢复鼠标位置（用 CGEvent 以确保系统状态同步）
        if let restoreEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                       mouseCursorPosition: savedCursorCG, mouseButton: .left) {
            restoreEvent.post(tap: .cghidEventTap)
        }

        // 恢复前台应用焦点 — CGEvent 鼠标移动会激活副屏上的应用（通常是 Chrome）
        savedFrontApp?.activate(options: .activateIgnoringOtherApps)

        if success {
            usleep(100_000) // 等空间切换动画
            // 验证 space 是否真正切换成功
            let postFallbackSpace = queryFocusedSpace()?.index
            let reachedTarget = postFallbackSpace == spaceIndex
            log(
                "[SpaceController] CGEvent fallback completed",
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex),
                    "preFocusSpace": String(describing: preFocusSpace),
                    "postFallbackSpace": String(describing: postFallbackSpace),
                    "reachedTarget": String(reachedTarget)
                ]
            )
            return reachedTarget
        }

        markOperationError(from: result.failure, fallback: "Failed to focus space \(spaceIndex)", operationID: op)
        return false
    }

    func calculateFocusSteps(targetSpaceIndex: Int) -> Int {
        log(
            "[calculateFocusSteps] called",
            level: .debug,
            fields: ["targetSpaceIndex": String(targetSpaceIndex)]
        )
        guard let spaces = querySpaces() else {
            log("[SpaceController] calculateFocusSteps: querySpaces returned nil", level: .warn, fields: ["target": String(targetSpaceIndex)])
            return 0
        }

        // 找到目标空间所在的显示器
        guard let targetSpace = spaces.first(where: { $0.index == targetSpaceIndex }) else {
            log("[SpaceController] calculateFocusSteps: target space not found", level: .warn, fields: ["target": String(targetSpaceIndex)])
            return 0
        }
        log(
            "[calculateFocusSteps] found target space",
            level: .debug,
            fields: [
                "targetSpaceIndex": String(targetSpaceIndex),
                "targetDisplay": String(describing: targetSpace.display)
            ]
        )
        guard let displayIndex = targetSpace.display else {
            log("[SpaceController] calculateFocusSteps: target space has no display", level: .warn, fields: ["target": String(targetSpaceIndex)])
            return 0
        }

        // 找到该显示器上所有空间（按 index 排序）
        let displaySpaces = spaces
            .filter { $0.display == displayIndex }
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

        // 找到该显示器上当前可见空间
        guard let currentSpace = displaySpaces.first(where: { $0.isVisible == true }) else {
            log("[SpaceController] calculateFocusSteps: no visible space on display", level: .warn, fields: ["display": String(displayIndex)])
            return 0
        }
        guard let currentIdx = displaySpaces.firstIndex(where: { $0.index == currentSpace.index }) else { return 0 }
        guard let targetIdx = displaySpaces.firstIndex(where: { $0.index == targetSpaceIndex }) else { return 0 }

        let steps = targetIdx - currentIdx
        log(
            "[SpaceController] calculateFocusSteps",
            fields: [
                "target": String(targetSpaceIndex),
                "display": String(displayIndex),
                "displaySpaces": displaySpaces.map { "\($0.index ?? 0):v=\($0.isVisible ?? false)" }.joined(separator: ","),
                "currentIdx": String(currentIdx),
                "targetIdx": String(targetIdx),
                "steps": String(steps),
            ]
        )
        return steps
    }

    func displayCenterCG(spaceIndex: Int) -> CGPoint? {
        guard let spaces = querySpaces(),
              let targetSpace = spaces.first(where: { $0.index == spaceIndex }),
              let displayIndex = targetSpace.display else { return nil }

        // 查询 yabai 获取 display frame（不需要 scripting-addition）
        guard let result = runYabai(arguments: ["-m", "query", "--displays", "--display", String(displayIndex)]),
              result.exitCode == 0 else {
            log("[SpaceController] displayCenterCG: yabai display query failed", level: .warn, fields: [
                "displayIndex": String(displayIndex)
            ])
            return nil
        }

        guard let info = decodeSingleOrFirst(YabaiDisplayInfo.self, from: result.stdout),
              let frame = info.frame else {
            log("[SpaceController] displayCenterCG: failed to parse display frame", level: .warn, fields: [
                "displayIndex": String(displayIndex), "stdout": String(result.stdout.prefix(200))
            ])
            return nil
        }

        // yabai frame 使用 CG 坐标系（原点在主屏左上角，Y 向下），与 CGEvent 一致
        return CGPoint(
            x: frame.x + frame.w / 2,
            y: frame.y + frame.h / 2
        )
    }

    private func saveAndMoveCursor(toSpace spaceIndex: Int, operationID: String) -> (savedCursor: CGPoint, savedApp: NSRunningApplication?)? {
        let op = operationID
        let savedFrontApp = NSWorkspace.shared.frontmostApplication
        let savedCursor = NSEvent.mouseLocation
        let mainScreenHeight = NSScreen.screens[0].frame.height
        let savedCursorCG = CGPoint(x: savedCursor.x, y: mainScreenHeight - savedCursor.y)

        log("[SpaceController] saveAndMoveCursor", level: .debug, fields: [
            "op": op,
            "spaceIndex": String(spaceIndex),
            "savedCursorNS": "\(Int(savedCursor.x)),\(Int(savedCursor.y))",
            "savedCursorCG": "\(Int(savedCursorCG.x)),\(Int(savedCursorCG.y))",
            "savedApp": savedFrontApp?.localizedName ?? "nil"
        ])

        if let center = displayCenterCG(spaceIndex: spaceIndex) {
            log("[SpaceController] saveAndMoveCursor: moving cursor to target display center", level: .debug, fields: [
                "op": op,
                "targetCenter": "\(Int(center.x)),\(Int(center.y))"
            ])
            if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                        mouseCursorPosition: center, mouseButton: .left) {
                moveEvent.post(tap: .cghidEventTap)
            }
            usleep(100_000)
            return (savedCursorCG, savedFrontApp)
        }
        log("[SpaceController] saveAndMoveCursor: cannot determine display center", level: .warn, fields: [
            "op": operationID, "spaceIndex": String(spaceIndex)
        ])
        return nil
    }

    private func restoreCursor(_ savedCursor: CGPoint, savedApp: NSRunningApplication?) {
        log("[SpaceController] restoreCursor", level: .debug, fields: [
            "targetCursorCG": "\(Int(savedCursor.x)),\(Int(savedCursor.y))",
            "savedApp": savedApp?.localizedName ?? "nil"
        ])
        if let restoreEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                       mouseCursorPosition: savedCursor, mouseButton: .left) {
            restoreEvent.post(tap: .cghidEventTap)
        }
        savedApp?.activate(options: .activateIgnoringOtherApps)
    }
}
