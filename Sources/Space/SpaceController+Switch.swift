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

        // Strategy 1: yabai -m space --focus (需要 SA)
        let yabaiResult = runYabai(
            arguments: ["-m", "space", "--focus", String(targetSpace)],
            operation: "switchDisplayToSpace_yabai",
            operationID: op
        )
        if let result = yabaiResult, result.exitCode == 0 {
            return true
        }

        log("[SpaceController] switchDisplayToSpace: yabai failed, trying CGEvent fallback", level: .info, fields: [
            "op": op, "targetSpace": String(targetSpace)
        ])

        // Strategy 2: CGEvent — 先用 yabai 激活目标 display，再 Ctrl+Left/Right
        let steps = calculateFocusSteps(targetSpaceIndex: targetSpace)

        // 先用 yabai display --focus 激活目标 display（不需要 SA）
        if let targetDisplayIdx = querySpaces()?.first(where: { $0.index == targetSpace })?.display {
            let focusResult = runYabai(
                arguments: ["-m", "display", "--focus", String(targetDisplayIdx)],
                operation: "switchDisplayToSpace_display_focus",
                operationID: op
            )
            if let result = focusResult, result.exitCode == 0 {
                usleep(30_000)
            } else {
                log("[SpaceController] switchDisplayToSpace: yabai display focus failed, relying on cursor move", level: .info, fields: [
                    "op": op, "targetDisplay": String(targetDisplayIdx)
                ])
            }
        }

        guard steps != 0 else {
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
            usleep(80_000)
            let postSwitchSpace = displayVisibleSpace(displayIndex: querySpaces()?.first(where: { $0.index == targetSpace })?.display)
            let reachedTarget = postSwitchSpace == targetSpace
            log("[SpaceController] switchDisplayToSpace: CGEvent result", fields: [
                "op": op,
                "targetSpace": String(targetSpace),
                "steps": String(steps),
                "postSwitchSpace": String(describing: postSwitchSpace),
                "reachedTarget": String(reachedTarget)
            ])
            if reachedTarget {
                return true
            }
            log("[SpaceController] switchDisplayToSpace: CGEvent sent but space didn't change", level: .warn, fields: [
                "op": op,
                "targetSpace": String(targetSpace),
                "postSwitchSpace": String(describing: postSwitchSpace)
            ])
        }

        log("[SpaceController] switchDisplayToSpace: all strategies failed", level: .error, fields: [
            "op": op, "targetSpace": String(targetSpace)
        ])
        return false
    }

    func focusSpace(_ spaceIndex: Int, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return false
        }
        guard canControlSpaces else {
            markOperationError("Cannot focus another space because cross-space control is unavailable", operationID: op)
            return false
        }

        let preFocusSpace = queryFocusedSpace()?.index
        let targetDisplay = querySpaces()?.first(where: { $0.index == spaceIndex })?.display

        let variants = [["-m", "space", "--focus", "\(spaceIndex)"]]
        let result = runYabaiVariants(variants: variants, operation: "focusSpace(\(spaceIndex))", operationID: op)
        if result.success {
            return true
        }

        // yabai 失败，使用 CGEvent 键盘事件 fallback
        let steps = calculateFocusSteps(targetSpaceIndex: spaceIndex)
        log(
            "[SpaceController] yabai focusSpace failed, trying CGEvent fallback",
            fields: [
                "op": op,
                "yabaiIndex": String(spaceIndex),
                "targetDisplay": String(describing: targetDisplay),
                "steps": String(steps)
            ]
        )

        if steps == 0 {
            let currentGlobalSpace = queryFocusedSpace()?.index
            if currentGlobalSpace == spaceIndex {
                return true
            }

            if let (savedCursor, savedApp) = saveAndMoveCursor(toSpace: spaceIndex, operationID: op, click: false) {
                restoreCursor(savedCursor, savedApp: savedApp)
            }

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
        let saved = saveAndMoveCursor(toSpace: spaceIndex, operationID: op, click: false)

        let success = NativeSpaceBridge.focusSpace(steps: steps, operationID: op)

        if let (savedCursor, savedApp) = saved {
            restoreCursor(savedCursor, savedApp: savedApp)
        }

        if success {
            usleep(100_000)
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
        guard let spaces = querySpaces() else {
            log("[SpaceController] calculateFocusSteps: querySpaces returned nil", level: .warn, fields: ["target": String(targetSpaceIndex)])
            return 0
        }

        guard let targetSpace = spaces.first(where: { $0.index == targetSpaceIndex }) else {
            log("[SpaceController] calculateFocusSteps: target space not found", level: .warn, fields: ["target": String(targetSpaceIndex)])
            return 0
        }

        guard let displayIndex = targetSpace.display else {
            log("[SpaceController] calculateFocusSteps: target space has no display", level: .warn, fields: ["target": String(targetSpaceIndex)])
            return 0
        }

        let displaySpaces = spaces
            .filter { $0.display == displayIndex }
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

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

        return CGPoint(
            x: frame.x + frame.w / 2,
            y: frame.y + frame.h / 2
        )
    }

    private func saveAndMoveCursor(toSpace spaceIndex: Int, operationID: String, click: Bool = true) -> (savedCursor: CGPoint, savedApp: NSRunningApplication?)? {
        let savedFrontApp = NSWorkspace.shared.frontmostApplication
        let savedCursor = NSEvent.mouseLocation
        let mainScreenHeight = CoordinateKit.mainScreenHeight
        let savedCursorCG = CGPoint(x: savedCursor.x, y: mainScreenHeight - savedCursor.y)

        if let center = displayCenterCG(spaceIndex: spaceIndex) {
            if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                        mouseCursorPosition: center, mouseButton: .left) {
                moveEvent.post(tap: .cghidEventTap)
            }
            usleep(50_000)
            if click {
                if let downClick = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                            mouseCursorPosition: center, mouseButton: .left) {
                    downClick.post(tap: .cghidEventTap)
                }
                usleep(20_000)
                if let upClick = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                          mouseCursorPosition: center, mouseButton: .left) {
                    upClick.post(tap: .cghidEventTap)
                }
                usleep(100_000)
            }
            return (savedCursorCG, savedFrontApp)
        }
        log("[SpaceController] saveAndMoveCursor: cannot determine display center", level: .warn, fields: [
            "op": operationID, "spaceIndex": String(spaceIndex)
        ])
        return nil
    }

    private func restoreCursor(_ savedCursor: CGPoint, savedApp: NSRunningApplication?) {
        if let restoreEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                       mouseCursorPosition: savedCursor, mouseButton: .left) {
            restoreEvent.post(tap: .cghidEventTap)
        }
        savedApp?.activate(options: .activateIgnoringOtherApps)
    }
}
