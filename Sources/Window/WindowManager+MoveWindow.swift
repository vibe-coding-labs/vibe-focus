import SwiftUI
import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - Window Move Operations
// 窗口移动核心逻辑：resolve、moveToMainScreen、验证
@MainActor
extension WindowManager {

    private static let cgPollTimeoutMs: useconds_t = 80_000
    private static let heightTolerance: CGFloat = 100

    /// 执行 shell 命令并返回输出 — 委托到 ShellRunner
    func runShellCommand(_ executable: String, args: [String]) -> String? {
        return ShellRunner.run(executable: executable, arguments: args)?.stdout
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

        guard let origFrame = frame(of: windowAX) else {
            log(
                "moveWindowToMainScreen failed: cannot read current frame",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        // 检查窗口是否已在主屏幕上
        // 使用 yabai display 信息作为主要判断依据
        // AX frame 对非可见工作区的窗口不可靠（macOS 会报告错误的坐标）
        let yabaiDisplay = spaceController.windowDisplayIndex(windowID: identity.windowID)
        if let display = yabaiDisplay?.yabaiIndex, display != 1 {
            // yabai 报告窗口在副显示器上，即使 AX frame 看起来在主屏也继续移动
            log(
                "[WindowManager] yabai reports window on secondary display, proceeding with move",
                fields: [
                    "op": op,
                    "windowID": String(identity.windowID),
                    "yabaiDisplay": String(describing: yabaiDisplay),
                    "axFrame": "\(origFrame)"
                ]
            )
        } else if let mainScreen = getMainScreen() {
            let mainScreenFrame = mainScreen.frame
            let windowCenter = CGPoint(x: origFrame.midX, y: origFrame.midY)
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

        guard let axWindowID = windowHandle(for: windowAX) else {
            log(
                "moveWindowToMainScreen failed: missing stable window handle",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        // 验证 AX resolve 的窗口 ID 与请求的窗口 ID 一致
        // 如果不一致，说明 resolveWindow 匹配到了错误的窗口
        let effectiveWindowID: UInt32
        if axWindowID != identity.windowID {
            log(
                "[moveWindowToMainScreen] windowID mismatch: AX resolved \(axWindowID) but requested \(identity.windowID), using identity.windowID",
                level: .warn,
                fields: [
                    "op": op,
                    "requestedWindowID": String(identity.windowID),
                    "resolvedWindowID": String(axWindowID),
                    "pid": String(identity.pid)
                ]
            )
            effectiveWindowID = identity.windowID
        } else {
            effectiveWindowID = identity.windowID
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

        let sourceContext = displayContext(for: origFrame)
        let spaceCaptureStartAt = Date()
        let spaceContext = spaceController.captureSpaceContext(windowID: effectiveWindowID, operationID: op)
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

        // 尝试通过 AX 设置窗口位置
        // apply() 内部已含容差检查（高度 100px），返回 true 表示窗口已在目标位置附近
        let axApplySucceeded = apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main_apply_frame")

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

            // 轮询验证 AX 是否实际成功（AX apply 返回 false 但可能实际已生效）
            let cgVerified = pollUntil_axFrameMatch(
                windowID: identity.windowID,
                targetFrame: targetFrame,
                timeout: Self.cgPollTimeoutMs,
                operationID: op
            )

            if !cgVerified {
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

        // AX-safe: reading frame after move to main screen — window is visible
        // 使用实际应用的 frame（可能因 macOS 菜单栏调整而与理想 targetFrame 不同）
        let actualTargetFrame = frame(of: windowAX) ?? targetFrame

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
        // 写入: ToggleEngine（SQLite 单一事实来源，restore 时直接读这里）
        // 如果 space context 全部为 nil（yabai 不可用），不保存 toggle record
        // 因为 sourceSpace=0 是无效的 yabai index，恢复时会发到错误的 space
        if let sourceSpaceIndex = spaceContext.sourceSpaceIndex {
            let teSourceDisplay: DisplayIdentifier = spaceContext.sourceDisplayIndex ?? sourceContext.index.map { .yabai($0) } ?? .yabai(0)
            // 窗口移动后 CGWindowNumber 可能变化，重新读取 AX element 的 windowID
            let postMoveWindowID = windowHandle(for: windowAX) ?? effectiveWindowID
            if postMoveWindowID != effectiveWindowID {
                log(
                    "[WindowManager] moveWindowToMainScreen: CGWindowNumber changed after move",
                    level: .info,
                    fields: [
                        "op": op,
                        "beforeMoveWindowID": String(effectiveWindowID),
                        "afterMoveWindowID": String(postMoveWindowID)
                    ]
                )
                SessionWindowRegistry.shared.remapWindowID(oldWindowID: effectiveWindowID, newWindowID: postMoveWindowID)
            }
            ToggleEngine.shared.save(
                windowID: postMoveWindowID,
                pid: identity.pid,
                bundleIdentifier: identity.bundleIdentifier,
                appName: identity.appName,
                origFrame: origFrame,
                sourceSpace: sourceSpaceIndex,
                sourceDisplay: teSourceDisplay,
                sourceYabaiDisp: spaceContext.sourceDisplayIndex ?? .yabai(0),
                sourceDispSpace: spaceContext.sourceDisplaySpaceIndex ?? 0,
                targetFrame: actualTargetFrame,
                targetDisplay: targetDisplayIndex ?? 0,
                sessionID: sessionID
            )
        } else {
            log("[WindowManager] skipping ToggleEngine.save — space context unavailable (yabai may not be running)", level: .warn, fields: ["op": op])
        }

        log(
            "[WindowManager] moveWindowToMainScreen finished",
            fields: [
                "op": op,
                "windowID": String(effectiveWindowID),
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
        let windows = cgWindowListAll()
        guard let entry = windows.first(where: { $0.windowID == windowID }) else {
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
        guard let actualFrame = entry.bounds else {
            return false
        }

        let positionMatches = abs(actualFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
                             abs(actualFrame.origin.y - targetFrame.origin.y) <= frameTolerance
        let sizeClose = abs(actualFrame.width - targetFrame.width) <= frameTolerance * 2 &&
                       abs(actualFrame.height - targetFrame.height) <= Self.heightTolerance

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

    /// 轮询验证窗口 frame 是否已到达目标（通过 CGWindowList）
    private func pollUntil_axFrameMatch(
        windowID: UInt32,
        targetFrame: CGRect,
        timeout: useconds_t,
        operationID: String
    ) -> Bool {
        let start = Date()
        let timeoutSec = Double(timeout) / 1_000_000
        while Date().timeIntervalSince(start) < timeoutSec {
            if verifyWindowFrameViaCGWindowList(windowID: windowID, targetFrame: targetFrame, operationID: operationID) {
                return true
            }
            usleep(15_000)
        }
        return verifyWindowFrameViaCGWindowList(windowID: windowID, targetFrame: targetFrame, operationID: operationID)
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
