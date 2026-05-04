import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation

// MARK: - Window Move Operations
// 窗口移动核心逻辑：resolve、moveToMainScreen、验证
@MainActor
extension WindowManager {

    /// 执行 shell 命令并返回输出
    func runShellCommand(_ executable: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    func resolveWindow(identity: WindowIdentity) -> AXUIElement? {
        log(
            "[WindowManager] resolveWindow called",
            level: .debug,
            fields: [
                "windowID": String(identity.windowID),
                "pid": String(identity.pid),
                "bundleID": identity.bundleIdentifier ?? "nil",
                "title": truncateForLog(identity.title ?? "", limit: 60)
            ]
        )
        let pid = pid_t(identity.pid)
        if let focused = focusedWindow(for: pid),
           let focusedID = windowHandle(for: focused),
           focusedID == identity.windowID {
            log(
                "[WindowManager] resolveWindow: matched focused window",
                level: .debug,
                fields: ["windowID": String(identity.windowID)]
            )
            return focused
        }

        let windows = allWindows(for: pid)
        if let exactID = windows.first(where: { window in
            guard let currentID = windowHandle(for: window) else { return false }
            return currentID == identity.windowID
        }) {
            return exactID
        }

        if let number = identity.windowNumber,
           let matched = windows.first(where: { windowNumber(for: $0) == number }) {
            return matched
        }

        if let expectedTitle = identity.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expectedTitle.isEmpty,
           let matched = windows.first(where: {
               self.title(of: $0)?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedTitle
           }) {
            return matched
        }

        return windows.first
    }

    @discardableResult
    func moveWindowToMainScreen(
        identity: WindowIdentity,
        reason: WindowMoveReason,
        sessionID: String?,
        operationID: String? = nil
    ) -> Bool {
        let op = operationID ?? makeOperationID(prefix: "move")
        let startedAt = Date()
        log(
            "[WindowManager] moveWindowToMainScreen started",
            fields: [
                "op": op,
                "windowID": String(identity.windowID),
                "pid": String(identity.pid),
                "reason": reason.rawValue,
                "sessionID": sessionID ?? "nil"
            ]
        )

        guard hasAccessibilityPermission() else {
            log(
                "moveWindowToMainScreen failed: accessibility not granted",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            notifyAccessibilityPermissionRequired()
            return false
        }

        log(
            "[moveWindowToMainScreen] AX permission OK, resolving window",
            level: .debug,
            fields: [
                "op": op,
                "windowID": String(identity.windowID),
                "pid": String(identity.pid)
            ]
        )

        guard let windowAX = resolveWindow(identity: identity) else {
            log(
                "moveWindowToMainScreen failed: cannot resolve window",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        log(
            "[moveWindowToMainScreen] resolved window AX element",
            level: .debug,
            fields: [
                "op": op,
                "windowID": String(identity.windowID)
            ]
        )

        guard let currentFrame = frame(of: windowAX) else {
            log(
                "moveWindowToMainScreen failed: cannot read current frame",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        log(
            "[moveWindowToMainScreen] read current frame",
            level: .debug,
            fields: [
                "op": op,
                "currentFrame": String(describing: currentFrame)
            ]
        )

        // 检查窗口是否已在主屏幕上
        // 使用 yabai display 信息作为主要判断依据
        // AX frame 对非可见工作区的窗口不可靠（macOS 会报告错误的坐标）
        log(
            "[moveWindowToMainScreen] checking if window already on main screen",
            level: .debug,
            fields: ["op": op]
        )
        let yabaiDisplay = spaceController.windowDisplayIndex(windowID: identity.windowID)
        if let display = yabaiDisplay, display != 1 {
            // yabai 报告窗口在副显示器上，即使 AX frame 看起来在主屏也继续移动
            log(
                "[WindowManager] yabai reports window on secondary display, proceeding with move",
                fields: [
                    "op": op,
                    "windowID": String(identity.windowID),
                    "yabaiDisplay": String(display),
                    "axFrame": "\(currentFrame)"
                ]
            )
        } else if let mainScreen = getMainScreen() {
            let mainScreenFrame = mainScreen.frame
            let windowCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
            if mainScreenFrame.contains(windowCenter) {
                log(
                    "[WindowManager] moveWindowToMainScreen skipped: already on main screen",
                    fields: [
                        "op": op,
                        "windowID": String(identity.windowID),
                        "reason": reason.rawValue,
                        "yabaiDisplay": yabaiDisplay.map(String.init) ?? "nil"
                    ]
                )
                return true
            }
        }

        log(
            "[moveWindowToMainScreen] window not on main screen, getting window handle",
            level: .debug,
            fields: ["op": op]
        )

        guard let currentWindowID = windowHandle(for: windowAX) else {
            log(
                "moveWindowToMainScreen failed: missing stable window handle",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        guard isAttributeSettable(windowAX, attribute: kAXPositionAttribute),
              isAttributeSettable(windowAX, attribute: kAXSizeAttribute) else {
            log(
                "moveWindowToMainScreen failed: window attributes not settable",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        log(
            "[moveWindowToMainScreen] got window handle, checking settable attributes",
            level: .debug,
            fields: [
                "op": op,
                "currentWindowID": String(currentWindowID)
            ]
        )

        let sourceContext = displayContext(for: currentFrame)
        let spaceCaptureStartAt = Date()
        let spaceContext = spaceController.captureSpaceContext(windowID: currentWindowID, operationID: op)
        log(
            "[WindowManager] captured source space context",
            fields: [
                "op": op,
                "durationMs": String(elapsedMilliseconds(since: spaceCaptureStartAt))
            ]
        )

        guard let mainScreen = getMainScreen() else {
            log(
                "moveWindowToMainScreen failed: cannot determine main screen",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        let targetFrame = axFrame(forVisibleFrameOf: mainScreen)
        let targetDisplayID = displayID(for: mainScreen)
        let targetDisplayIndex = displayIndex(forDisplayID: targetDisplayID)

        log(
            "[moveWindowToMainScreen] computed target frame and display",
            level: .debug,
            fields: [
                "op": op,
                "targetFrame": String(describing: targetFrame),
                "targetDisplayID": String(describing: targetDisplayID),
                "targetDisplayIndex": String(describing: targetDisplayIndex)
            ]
        )

        // 尝试通过 AX 设置窗口位置
        // apply() 内部已含容差检查（高度 100px），返回 true 表示窗口已在目标位置附近
        log(
            "[moveWindowToMainScreen] calling apply() to set frame",
            level: .debug,
            fields: [
                "op": op,
                "targetFrame": String(describing: targetFrame)
            ]
        )
        let axApplySucceeded = apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main_apply_frame")
        log(
            "[moveWindowToMainScreen] apply() returned",
            level: .debug,
            fields: [
                "op": op,
                "axApplySucceeded": String(axApplySucceeded)
            ]
        )

        if !axApplySucceeded {
            // apply 本身失败 — 尝试 CGWindowList 验证后重试
            log(
                "[WindowManager] AX apply failed, trying CGWindowList fallback + retry",
                level: .warn,
                fields: [
                    "op": op,
                    "windowID": String(identity.windowID)
                ]
            )

            usleep(100_000)

            let cgVerified = verifyWindowFrameViaCGWindowList(
                windowID: identity.windowID,
                targetFrame: targetFrame,
                operationID: op
            )

            if !cgVerified {
                usleep(150_000)
                let retrySucceeded = apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main_apply_frame_retry")
                if !retrySucceeded {
                    log(
                        "moveWindowToMainScreen failed: all attempts exhausted",
                        level: .error,
                        fields: [
                            "op": op,
                            "targetFrame": String(describing: targetFrame)
                        ]
                    )
                    return false
                }
            }
        }

        // 使用实际应用的 frame（可能因 macOS 菜单栏调整而与理想 targetFrame 不同）
        let actualTargetFrame = frame(of: windowAX) ?? targetFrame

        log(
            "[moveWindowToMainScreen] move succeeded, capturing state for persistence",
            level: .debug,
            fields: [
                "op": op,
                "actualTargetFrame": String(describing: actualTargetFrame),
                "requestedTargetFrame": String(describing: targetFrame)
            ]
        )

        let resolvedWindowNumber = windowNumber(for: windowAX) ?? identity.windowNumber
        let resolvedTitle = title(of: windowAX) ?? identity.title
        log(
            "[WindowManager] moveWindowToMainScreen captured state",
            fields: [
                "op": op,
                "sourceSpace": String(describing: spaceContext.sourceSpaceIndex),
                "targetSpace": String(describing: spaceContext.targetSpaceIndex),
                "sourceYabaiDisplay": String(describing: spaceContext.sourceDisplayIndex),
                "sourceDisplaySpace": String(describing: spaceContext.sourceDisplaySpaceIndex),
                "sourceDisplayID": String(describing: sourceContext.displayID),
                "sourceDisplayIndex": String(describing: sourceContext.index),
                "targetDisplayIndex": String(describing: targetDisplayIndex),
                "targetFrame": String(describing: targetFrame),
                "actualTargetFrame": String(describing: actualTargetFrame)
            ]
        )
        let savedState = SavedWindowState(
            id: UUID().uuidString,
            pid: identity.pid,
            bundleIdentifier: identity.bundleIdentifier,
            appName: identity.appName,
            windowID: currentWindowID,
            windowNumber: resolvedWindowNumber,
            title: resolvedTitle,
            originalFrame: RectPayload(currentFrame),
            targetFrame: RectPayload(actualTargetFrame),
            sourceSpaceIndex: spaceContext.sourceSpaceIndex,
            targetSpaceIndex: spaceContext.targetSpaceIndex,
            sourceYabaiDisplayIndex: spaceContext.sourceDisplayIndex,
            sourceDisplaySpaceIndex: spaceContext.sourceDisplaySpaceIndex,
            sourceDisplayIndex: sourceContext.index,
            sourceDisplayID: sourceContext.displayID,
            targetDisplayIndex: targetDisplayIndex,
            restoreReason: reason.rawValue,
            sessionID: sessionID,
            savedAt: Date()
        )

        let persistedState = saveWindowState(savedState, window: windowAX)
        log(
            "[moveWindowToMainScreen] saved window state",
            level: .debug,
            fields: [
                "op": op,
                "stateID": persistedState.id
            ]
        )
        hydrateMemory(from: persistedState, window: windowAX)
        log(
            "[moveWindowToMainScreen] hydrated memory from persisted state",
            level: .debug,
            fields: [
                "op": op,
                "stateID": persistedState.id
            ]
        )
        log(
            "[WindowManager] moveWindowToMainScreen finished",
            fields: [
                "op": op,
                "savedStateID": persistedState.id,
                "windowID": String(currentWindowID),
                "durationMs": String(elapsedMilliseconds(since: startedAt))
            ]
        )
        return true
    }

    /// 通过 CGWindowList 验证窗口是否已移动到目标 frame
    /// CGWindowList 使用 WindowServer 的数据，不依赖 AX，对跨 space 窗口更可靠
    private func verifyWindowFrameViaCGWindowList(
        windowID: UInt32,
        targetFrame: CGRect,
        operationID: String
    ) -> Bool {
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for info in windowList {
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  id == windowID else { continue }

            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                return false
            }

            let actualFrame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )

            let positionMatches = abs(actualFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
                                 abs(actualFrame.origin.y - targetFrame.origin.y) <= frameTolerance
            let sizeClose = abs(actualFrame.width - targetFrame.width) <= frameTolerance * 2 &&
                           abs(actualFrame.height - targetFrame.height) <= 100

            log(
                "[WindowManager] CGWindowList frame verification",
                fields: [
                    "op": operationID,
                    "windowID": String(windowID),
                    "actualFrame": String(describing: actualFrame),
                    "targetFrame": String(describing: targetFrame),
                    "positionMatches": String(positionMatches),
                    "sizeClose": String(sizeClose)
                ]
            )

            return positionMatches && sizeClose
        }

        log(
            "[WindowManager] CGWindowList verification: window not found in list",
            level: .warn,
            fields: [
                "op": operationID,
                "windowID": String(windowID)
            ]
        )
        return false
    }

    private func allWindows(for pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let windowsRef else {
            log(
                "[WindowManager] allWindows: AX query failed",
                level: .debug,
                fields: ["pid": String(pid), "axStatus": String(status.rawValue)]
            )
            return []
        }
        let windows = windowsRef as? [AXUIElement] ?? []
        log(
            "[WindowManager] allWindows result",
            level: .debug,
            fields: ["pid": String(pid), "count": String(windows.count)]
        )
        return windows
    }

}
