import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation

// MARK: - Window Manager
@MainActor
class WindowManager {
    static let shared = WindowManager()

    let savedStatesKey = "savedWindowStates"
    let spaceController = SpaceController.shared
    var windowElementsByStateID: [String: AXUIElement] = [:]
    var lastWindowElement: AXUIElement?
    var lastWindowToken: WindowToken?
    var lastWindowFrame: CGRect?
    var lastTargetFrame: CGRect?
    var lastSourceSpaceIndex: Int?
    var lastTargetSpaceIndex: Int?
    var lastSourceYabaiDisplayIndex: Int?
    var lastSourceDisplaySpaceIndex: Int?
    var savedWindowStates: [SavedWindowState] = []
    var didPromptForAccessibility = false
    let frameTolerance: CGFloat = 10
    let axWindowNumberAttribute = "AXWindowNumber"
    let axFrameAttribute = "AXFrame"

    struct WindowToken {
        let stateID: String
        let pid: pid_t
        let bundleIdentifier: String?
        let appName: String?
        let windowID: UInt32?
        let windowNumber: Int?
        let title: String?
    }

    struct RectPayload: Codable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    struct SavedWindowState: Codable {
        let id: String
        let pid: Int32
        let bundleIdentifier: String?
        let appName: String?
        let windowID: UInt32?
        let windowNumber: Int?
        let title: String?
        let originalFrame: RectPayload
        let targetFrame: RectPayload
        let sourceSpaceIndex: Int?
        let targetSpaceIndex: Int?
        let sourceYabaiDisplayIndex: Int?
        let sourceDisplaySpaceIndex: Int?
        let sourceDisplayIndex: Int?
        let sourceDisplayID: UInt32?
        let targetDisplayIndex: Int?
        let restoreReason: String?
        let sessionID: String?
        let savedAt: Date
    }

    struct ScriptWindowSnapshot: Codable {
        let windowID: UInt32?
        let appName: String
        let title: String?
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        var frame: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    init() {
        savedWindowStates = loadSavedWindowStates()
        if !savedWindowStates.isEmpty {
            log("Loaded persisted window states from disk: \(savedWindowStates.count)")
        }
        evictExpiredStates()
    }

    /// 清理超过 maxAge 的 savedWindowStates，防止无限增长
    private func evictExpiredStates() {
        let maxAge: TimeInterval = 24 * 60 * 60  // 24 小时
        let now = Date()
        let before = savedWindowStates.count
        savedWindowStates.removeAll { state in
            now.timeIntervalSince(state.savedAt) > maxAge
        }
        let removed = before - savedWindowStates.count
        if removed > 0 {
            persistSavedWindowStates()
            log(
                "[WindowManager] evicted expired states",
                fields: [
                    "removed": String(removed),
                    "remaining": String(savedWindowStates.count),
                    "maxAgeHours": "24"
                ]
            )
        }
    }

    func toggle(operationID: String? = nil, triggerSource: String = "unknown") {
        let op = operationID ?? makeOperationID(prefix: "toggle")
        let startedAt = Date()
        let frontBefore = frontmostAppDescriptor()

        // 采集当前窗口上下文
        var toggleContext: [String: String] = [
            "op": op,
            "source": triggerSource,
            "savedStates": String(savedWindowStates.count),
            "frontBefore": frontBefore
        ]
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let focusedWin = focusedWindow(for: frontApp.processIdentifier) {
            let winTitle = title(of: focusedWin) ?? ""
            let winFrame = frame(of: focusedWin)
            let winID = windowHandle(for: focusedWin)
            toggleContext["windowID"] = String(describing: winID)
            toggleContext["windowTitle"] = truncateForLog(winTitle, limit: 60)
            toggleContext["windowFrame"] = String(describing: winFrame)
            // 判断窗口在哪个屏幕上
            if let winFrame,
               let mainScreen = getMainScreen() {
                let windowCenter = CGPoint(x: winFrame.midX, y: winFrame.midY)
                let onMainScreen = mainScreen.frame.contains(windowCenter)
                toggleContext["onMainScreen"] = String(onMainScreen)
            }
        }
        log(
            "[WindowManager] toggle started",
            fields: toggleContext
        )

        let shouldRestore = shouldRestoreCurrentWindow()
        log(
            "[WindowManager] toggle shouldRestoreCurrentWindow returned",
            level: .debug,
            fields: [
                "op": op,
                "shouldRestore": String(shouldRestore)
            ]
        )
        let mode = shouldRestore ? "restore" : "move_to_main"
        log(
            "[WindowManager] toggle decision",
            fields: [
                "op": op,
                "source": triggerSource,
                "mode": mode
            ]
        )

        if shouldRestore {
            log(
                "[WindowManager] toggle branching to restore",
                level: .debug,
                fields: ["op": op]
            )
            restore(operationID: op, triggerSource: triggerSource)
        } else {
            log(
                "[WindowManager] toggle branching to moveToMainScreen",
                level: .debug,
                fields: ["op": op]
            )
            moveToMainScreen(operationID: op, triggerSource: triggerSource)
        }

        log(
            "[WindowManager] toggle branch completed, checking frontmost app",
            level: .debug,
            fields: ["op": op]
        )
        let frontAfter = frontmostAppDescriptor()
        let durationMs = logOperationDuration(
            "[WindowManager] toggle finished",
            startedAt: startedAt,
            operationID: op,
            warnThresholdMs: 650,
            fields: [
                "source": triggerSource,
                "mode": mode,
                "frontBefore": frontBefore,
                "frontAfter": frontAfter
            ]
        )
        if frontBefore != frontAfter {
            log(
                "[WindowManager] frontmost app changed during toggle",
                level: .warn,
                fields: [
                    "op": op,
                    "source": triggerSource,
                    "mode": mode,
                    "frontBefore": frontBefore,
                    "frontAfter": frontAfter
                ]
            )
        }
        log(
            "[WindowManager] toggle checking slow threshold",
            level: .debug,
            fields: [
                "op": op,
                "durationMs": String(durationMs),
                "threshold": "650"
            ]
        )
        if durationMs >= 650 {
            CrashContextRecorder.shared.record("toggle_slow op=\(op) durationMs=\(durationMs) mode=\(mode)")
        }
    }

    func moveToMainScreen(operationID: String? = nil, triggerSource: String = "unknown") {
        let op = operationID ?? makeOperationID(prefix: "move")
        let startedAt = Date()
        log(
            "[WindowManager] move_to_main started",
            fields: [
                "op": op,
                "source": triggerSource
            ]
        )

        let axTrusted = hasAccessibilityPermission()
        log(
            "[WindowManager] accessibility check",
            fields: [
                "op": op,
                "axTrusted": String(axTrusted)
            ]
        )

        if !axTrusted {
            log(
                "[WindowManager] accessibility denied, fallback to System Events",
                level: .warn,
                fields: [
                    "op": op
                ]
            )
            CrashContextRecorder.shared.record("move_to_main_ax_denied op=\(op)")
            logDiagnostics("ax_trusted_false_move")
            moveToMainScreenViaSystemEvents()
            return
        }
        log(
            "[WindowManager] move_to_main AX OK, capturing focused window identity",
            level: .debug,
            fields: ["op": op]
        )
        guard let identity = captureFocusedWindowIdentity() else {
            log(
                "[WindowManager] move_to_main failed: focused window identity missing",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            CrashContextRecorder.shared.record("move_to_main_failed_identity_missing op=\(op)")
            return
        }
        log(
            "[WindowManager] move_to_main captured identity",
            level: .debug,
            fields: [
                "op": op,
                "windowID": String(identity.windowID),
                "pid": String(identity.pid)
            ]
        )
        let moved = moveWindowToMainScreen(
            identity: identity,
            reason: .manualHotkey,
            sessionID: nil,
            operationID: op
        )
        log(
            "[WindowManager] move_to_main moveWindowToMainScreen returned",
            level: .debug,
            fields: [
                "op": op,
                "moved": String(moved)
            ]
        )
        if moved {
            log(
                "MOVED AND MAXIMIZED ON TARGET SCREEN",
                fields: [
                    "op": op,
                    "durationMs": String(elapsedMilliseconds(since: startedAt))
                ]
            )
        } else {
            log(
                "MOVE FAILED",
                level: .error,
                fields: [
                    "op": op,
                    "durationMs": String(elapsedMilliseconds(since: startedAt))
                ]
            )
            CrashContextRecorder.shared.record("move_to_main_failed op=\(op)")
        }
    }

    func restore(operationID: String? = nil, triggerSource: String = "unknown") {
        let op = operationID ?? makeOperationID(prefix: "restore")
        let startedAt = Date()

        // 采集恢复操作的完整上下文
        var restoreContext: [String: String] = [
            "op": op,
            "source": triggerSource,
            "hasToken": String(lastWindowToken != nil),
            "hasOriginalFrame": String(lastWindowFrame != nil),
            "hasTargetFrame": String(lastTargetFrame != nil)
        ]
        if let token = lastWindowToken {
            restoreContext["tokenPID"] = String(token.pid)
            restoreContext["tokenBundleID"] = token.bundleIdentifier ?? "nil"
            restoreContext["tokenAppName"] = token.appName ?? "nil"
            restoreContext["tokenWindowID"] = String(describing: token.windowID)
            restoreContext["tokenTitle"] = truncateForLog(token.title ?? "", limit: 60)
        }
        if let frame = lastWindowFrame {
            restoreContext["originalFrame"] = String(describing: frame)
            // 判断 originalFrame 在哪个屏幕
            let center = CGPoint(x: frame.midX, y: frame.midY)
            for (idx, screen) in NSScreen.screens.enumerated() {
                if screen.frame.contains(center) {
                    restoreContext["originalScreenIndex"] = String(idx)
                    break
                }
            }
        }
        if let target = lastTargetFrame {
            restoreContext["targetFrame"] = String(describing: target)
        }
        restoreContext["sourceSpaceIndex"] = String(describing: lastSourceSpaceIndex)
        restoreContext["sourceYabaiDisplayIndex"] = String(describing: lastSourceYabaiDisplayIndex)
        log(
            "[WindowManager] restore started",
            fields: restoreContext
        )

        if !hasAccessibilityPermission() {
            log(
                "[WindowManager] restore fallback: accessibility denied",
                level: .warn,
                fields: [
                    "op": op
                ]
            )
            CrashContextRecorder.shared.record("restore_ax_denied op=\(op)")
            logDiagnostics("ax_trusted_false_restore")
            restoreViaSystemEvents()
            return
        }

        log(
            "[WindowManager] restore AX permission OK, checking active state",
            level: .debug,
            fields: [
                "op": op,
                "hasToken": String(lastWindowToken != nil),
                "hasFrame": String(lastWindowFrame != nil),
                "hasTarget": String(lastTargetFrame != nil)
            ]
        )

        if lastWindowToken == nil || lastWindowFrame == nil || lastTargetFrame == nil {
            log(
                "[WindowManager] restore some active state nil, calling shouldRestoreCurrentWindow",
                level: .debug,
                fields: ["op": op]
            )
            if shouldRestoreCurrentWindow() == false {
                log(
                    "[WindowManager] restore skipped: no saved state",
                    level: .warn,
                    fields: [
                        "op": op
                    ]
                )
                return
            }
            log(
                "[WindowManager] restore shouldRestoreCurrentWindow succeeded after nil check",
                level: .debug,
                fields: [
                    "op": op,
                    "hasToken": String(lastWindowToken != nil),
                    "hasFrame": String(lastWindowFrame != nil)
                ]
            )
        }

        guard let token = lastWindowToken, let frame = lastWindowFrame else {
            log(
                "[WindowManager] restore failed: active state missing",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            CrashContextRecorder.shared.record("restore_failed_no_active_state op=\(op)")
            return
        }

        log(
            "[WindowManager] restore resolved token and frame",
            level: .debug,
            fields: [
                "op": op,
                "tokenStateID": token.stateID,
                "tokenPID": String(token.pid),
                "tokenWindowID": String(describing: token.windowID),
                "targetFrame": String(describing: frame)
            ]
        )

        let spacePrepared = applySpaceStrategyForRestore(windowID: token.windowID, operationID: op)
        log(
            "[WindowManager] restore applySpaceStrategyForRestore returned",
            level: .debug,
            fields: [
                "op": op,
                "spacePrepared": String(spacePrepared)
            ]
        )
        if !spacePrepared {
            log(
                "[WindowManager] space restore preparation failed, fallback to frame-only restore",
                level: .warn,
                fields: [
                    "op": op
                ]
            )
        }

        guard let window = restoreWindow(using: token) else {
            log(
                "[WindowManager] restore failed: window not found",
                level: .error,
                fields: [
                    "op": op,
                    "tokenWindowID": String(describing: token.windowID)
                ]
            )
            CrashContextRecorder.shared.record("restore_failed_window_not_found op=\(op)")
            return
        }

        log(
            "[WindowManager] restore resolved window AX element",
            level: .debug,
            fields: [
                "op": op,
                "tokenWindowID": String(describing: token.windowID)
            ]
        )

        // 预检：如果窗口已在目标（原始）位置，跳过恢复
        // 防止对已恢复的窗口执行无意义操作，避免与手动快捷键操作冲突
        log(
            "[WindowManager] restore checking if window already at original position",
            level: .debug,
            fields: ["op": op]
        )
        if let currentFrame = self.frame(of: window),
           let targetFrame = lastWindowFrame,
           framesMatch(currentFrame, targetFrame) {
            log(
                "[WindowManager] restore skipped: window already at original position",
                fields: [
                    "op": op,
                    "currentFrame": String(describing: currentFrame),
                    "targetFrame": String(describing: targetFrame)
                ]
            )
            resetActiveWindowContext(removeState: true)
            CrashContextRecorder.shared.record("restore_skipped_already_at_original op=\(op)")
            return
        }

        // 诊断日志：记录找到的窗口的当前状态
        let restoredWindowFrame = self.frame(of: window)
        let restoredWindowID = windowHandle(for: window)
        let restoredWindowSpace = restoredWindowID.flatMap { spaceController.windowSpaceIndex(windowID: $0) }
        log(
            "[WindowManager] restore_found_window",
            fields: [
                "op": op,
                "windowID": String(describing: restoredWindowID),
                "currentFrame": String(describing: restoredWindowFrame),
                "windowActualSpace": String(describing: restoredWindowSpace),
                "spacePrepared": String(spacePrepared)
            ]
        )

        guard isAttributeSettable(window, attribute: kAXPositionAttribute) else {
            log(
                "[WindowManager] restore failed: position attribute not settable",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            CrashContextRecorder.shared.record("restore_failed_position_not_settable op=\(op)")
            return
        }

        log(
            "[WindowManager] restore position attribute is settable",
            level: .debug,
            fields: ["op": op]
        )

        guard isAttributeSettable(window, attribute: kAXSizeAttribute) else {
            log(
                "[WindowManager] restore failed: size attribute not settable",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            CrashContextRecorder.shared.record("restore_failed_size_not_settable op=\(op)")
            return
        }

        log(
            "[WindowManager] restore size attribute is settable, proceeding to apply",
            level: .debug,
            fields: ["op": op]
        )

        let preApplyFrame = self.frame(of: window)
        let preApplyWindowID = windowHandle(for: window)
        let preApplySpace = preApplyWindowID.flatMap { spaceController.windowSpaceIndex(windowID: $0) }
        log(
            "[WindowManager] restore_pre_apply_frame",
            fields: [
                "op": op,
                "windowID": String(describing: preApplyWindowID),
                "currentFrame": String(describing: preApplyFrame),
                "targetFrame": String(describing: frame),
                "windowActualSpace": String(describing: preApplySpace)
            ]
        )

        guard apply(frame: frame, to: window, operationID: op, stage: "restore_apply_frame") else {
            log(
                "[WindowManager] restore failed: apply frame failed",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            CrashContextRecorder.shared.record("restore_failed_apply_frame op=\(op)")
            return
        }

        log(
            "[WindowManager] restore apply() succeeded, reading back frame",
            level: .debug,
            fields: ["op": op]
        )

        guard let restoredFrame = self.frame(of: window) else {
            log(
                "[WindowManager] restore failed: cannot read back frame",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            CrashContextRecorder.shared.record("restore_failed_readback op=\(op)")
            return
        }

        let readbackWindowID = windowHandle(for: window)
        let readbackSpace = readbackWindowID.flatMap { spaceController.windowSpaceIndex(windowID: $0) }
        log(
            "[WindowManager] restore_post_apply_frame",
            fields: [
                "op": op,
                "appliedFrame": String(describing: restoredFrame),
                "targetFrame": String(describing: frame),
                "frameMatched": String(framesMatch(restoredFrame, frame)),
                "windowActualSpace": String(describing: readbackSpace)
            ]
        )

        guard framesMatch(restoredFrame, frame) else {
            log(
                "[WindowManager] restore failed: frame mismatch",
                level: .error,
                fields: [
                    "op": op,
                    "expected": String(describing: frame),
                    "actual": String(describing: restoredFrame)
                ]
            )
            CrashContextRecorder.shared.record("restore_failed_frame_mismatch op=\(op)")
            return
        }

        log(
            "[WindowManager] restore frame matched, resetting active context",
            level: .debug,
            fields: ["op": op]
        )
        resetActiveWindowContext(removeState: true)
        let outcome = spacePrepared ? "restored" : "restored_frame_only"
        let finalDurationMs = elapsedMilliseconds(since: startedAt)
        log(
            "[WindowManager] restore finished",
            fields: [
                "op": op,
                "outcome": outcome,
                "durationMs": String(finalDurationMs),
                "spacePrepared": String(spacePrepared)
            ]
        )
        CrashContextRecorder.shared.record("restore_success op=\(op) outcome=\(outcome) durationMs=\(finalDurationMs)")
    }

    func getMainScreen() -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        log(
            "[WindowManager] getMainScreen called",
            level: .debug,
            fields: [
                "mainDisplayID": String(mainDisplayID),
                "screenCount": String(NSScreen.screens.count)
            ]
        )
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            if let value = screen.deviceDescription[key] as? NSNumber,
               CGDirectDisplayID(value.uint32Value) == mainDisplayID {
                log(
                    "[WindowManager] getMainScreen found match",
                    level: .debug,
                    fields: ["screenNumber": String(value.uint32Value)]
                )
                return screen
            }
        }
        log(
            "[WindowManager] getMainScreen no exact match, using first or main",
            level: .debug,
            fields: ["fallback": NSScreen.screens.first != nil ? "first" : "main"]
        )
        return NSScreen.screens.first ?? NSScreen.main
    }

    func hasAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log(
            "[WindowManager] hasAccessibilityPermission checked",
            level: .debug,
            fields: ["trusted": String(trusted)]
        )
        return trusted
    }

    func notifyAccessibilityPermissionRequired() {
        guard !didPromptForAccessibility else {
            log(
                "[WindowManager] notifyAccessibilityPermissionRequired skipped: already prompted",
                level: .debug
            )
            return
        }

        log(
            "[WindowManager] notifyAccessibilityPermissionRequired: showing prompt",
            level: .debug
        )
        didPromptForAccessibility = true
        NSSound.beep()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func shouldRestoreCurrentWindow() -> Bool {
        log(
            "[WindowManager] shouldRestoreCurrentWindow called",
            level: .debug,
            fields: ["savedStatesCount": String(savedWindowStates.count)]
        )
        if !hasAccessibilityPermission() {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: no AX permission, using System Events",
                level: .debug
            )
            return shouldRestoreCurrentWindowViaSystemEvents()
        }

        guard !savedWindowStates.isEmpty,
              let frontApp = NSWorkspace.shared.frontmostApplication,
              let focusedWindow = focusedWindow(for: frontApp.processIdentifier) else {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: guard failed",
                level: .debug,
                fields: [
                    "savedStatesEmpty": String(savedWindowStates.isEmpty),
                    "hasFrontApp": String(NSWorkspace.shared.frontmostApplication != nil)
                ]
            )
            return false
        }

        let currentTitle = title(of: focusedWindow) ?? ""
        let currentFrame = frame(of: focusedWindow)
        guard let currentWindowID = windowHandle(for: focusedWindow) else {
            guard let currentFrame else {
                return false
            }

            if let matchedState = findStateByFallbackMatching(
                pid: frontApp.processIdentifier,
                title: currentTitle,
                frame: currentFrame
            ) {
                hydrateMemory(from: matchedState, window: focusedWindow)
                log(
                    "Detected moved window state via fallback matching (PID+title+position, no windowID)",
                    fields: [
                        "pid": String(frontApp.processIdentifier),
                        "title": truncateForLog(currentTitle, limit: 60),
                        "frame": String(describing: currentFrame),
                        "stateID": matchedState.id
                    ]
                )
                return true
            }

            return false
        }

        // 第一级匹配：通过 windowID（最可靠的方式）
        log(
            "[WindowManager] Checking windowID match",
            fields: [
                "currentWindowID": String(currentWindowID),
                "currentTitle": truncateForLog(currentTitle, limit: 60),
                "currentFrame": String(describing: currentFrame),
                "savedWindowIDs": savedWindowStates.map { String(describing: $0.windowID) }.joined(separator: ","),
                "savedCount": String(savedWindowStates.count)
            ]
        )
        if let matchedState = savedWindowStates.reversed().first(where: { $0.windowID == currentWindowID }) {
            if isSavedStateCorrupted(matchedState) {
                log(
                    "[WindowManager] Corrupted state detected (originalFrame on main screen), clearing",
                    level: .warn,
                    fields: [
                        "stateID": matchedState.id,
                        "windowID": String(describing: matchedState.windowID),
                        "originalFrame": String(describing: matchedState.originalFrame.cgRect),
                        "targetFrame": String(describing: matchedState.targetFrame.cgRect),
                        "savedAt": String(describing: matchedState.savedAt)
                    ]
                )
                clearSavedWindowState(id: matchedState.id)
                // 继续尝试第二级匹配，而不是直接返回 false
            } else {
                hydrateMemory(from: matchedState, window: focusedWindow)
                log(
                    "[WindowManager] Found match by windowID",
                    fields: [
                        "windowID": String(currentWindowID),
                        "stateID": matchedState.id,
                        "originalFrame": String(describing: matchedState.originalFrame.cgRect),
                        "targetFrame": String(describing: matchedState.targetFrame.cgRect),
                        "sourceSpace": String(describing: matchedState.sourceSpaceIndex),
                        "savedAt": String(describing: matchedState.savedAt)
                    ]
                )
                return true
            }
        } else {
            log("[WindowManager] No match by windowID")
        }

        // 第二级匹配：通过 PID + 窗口标题 + 大致位置（备用机制）
        if let currentFrame,
           let matchedState = findStateByFallbackMatching(
               pid: frontApp.processIdentifier,
               title: currentTitle,
               frame: currentFrame
           ) {
            if isSavedStateCorrupted(matchedState) {
                log(
                    "[WindowManager] fallback match found but state is corrupted, clearing",
                    level: .warn,
                    fields: [
                        "stateID": matchedState.id,
                        "windowID": String(describing: matchedState.windowID),
                        "originalFrame": String(describing: matchedState.originalFrame.cgRect),
                        "targetFrame": String(describing: matchedState.targetFrame.cgRect)
                    ]
                )
                clearSavedWindowState(id: matchedState.id)
            } else {
                hydrateMemory(from: matchedState, window: focusedWindow)
                log(
                    "Detected moved window state via fallback matching (PID+title+position)",
                    fields: [
                        "pid": String(frontApp.processIdentifier),
                        "title": truncateForLog(currentTitle, limit: 60),
                        "stateID": matchedState.id,
                        "originalFrame": String(describing: matchedState.originalFrame.cgRect),
                        "sourceSpace": String(describing: matchedState.sourceSpaceIndex)
                    ]
                )
                return true
            }
        }

        return false
    }

    /// 检测 saved state 是否被污染（originalFrame 在主屏幕上）
    /// 被污染的 state 是指窗口被移动时实际上已经在主屏幕上，
    /// 导致 originalFrame 和 targetFrame 都在主屏幕上。
    /// 使用这样的 state 做 restore 会让窗口从主屏"恢复"到主屏，毫无意义。
    func isSavedStateCorrupted(_ state: SavedWindowState) -> Bool {
        guard let mainScreen = getMainScreen() else {
            log(
                "[WindowManager] isSavedStateCorrupted: no main screen, returning false",
                level: .debug,
                fields: ["stateID": state.id]
            )
            return false
        }
        let mainScreenFrame = mainScreen.frame
        let originalFrame = state.originalFrame.cgRect
        let originalCenter = CGPoint(x: originalFrame.midX, y: originalFrame.midY)
        let targetFrame = state.targetFrame.cgRect
        let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)

        // originalFrame 和 targetFrame 的中心都在主屏幕上 → 被污染
        let originalOnMain = mainScreenFrame.contains(originalCenter)
        let targetOnMain = mainScreenFrame.contains(targetCenter)
        let corrupted = originalOnMain && targetOnMain
        log(
            "[WindowManager] isSavedStateCorrupted checked",
            level: .debug,
            fields: [
                "stateID": state.id,
                "originalOnMain": String(originalOnMain),
                "targetOnMain": String(targetOnMain),
                "corrupted": String(corrupted)
            ]
        )
        return corrupted
    }

    /// 备用匹配机制：当 windowID 匹配失败时使用
    /// 基于 PID + 窗口标题 + 大致位置进行匹配
    private func findStateByFallbackMatching(
        pid: pid_t,
        title: String,
        frame: CGRect
    ) -> SavedWindowState? {
        // 匹配条件：
        // 1. PID 相同
        // 2. 窗口标题相同（或都为空）
        // 3. 当前位置接近保存的 targetFrame（因为窗口已经被移动过）

        log(
            "[WindowManager] findStateByFallbackMatching called",
            level: .debug,
            fields: [
                "pid": String(pid),
                "title": truncateForLog(title, limit: 60),
                "frame": String(describing: frame),
                "savedStatesCount": String(savedWindowStates.count)
            ]
        )

        let positionTolerance: CGFloat = 50.0  // 位置容差 50 像素

        let result = savedWindowStates.reversed().first { state in
            // PID 必须匹配
            guard state.pid == pid else { return false }

            // 窗口标题必须匹配（都为空也算匹配）
            let stateTitle = state.title ?? ""
            let currentTitle = title
            guard stateTitle == currentTitle else { return false }

            // 当前窗口位置应该接近保存的 targetFrame（因为窗口已经被移动到主屏幕）
            let targetFrame = state.targetFrame.cgRect
            let xDiff = abs(frame.origin.x - targetFrame.origin.x)
            let yDiff = abs(frame.origin.y - targetFrame.origin.y)

            return xDiff <= positionTolerance && yDiff <= positionTolerance
        }
        if let result {
            log(
                "[WindowManager] findStateByFallbackMatching matched",
                level: .debug,
                fields: [
                    "stateID": result.id,
                    "matchedWindowID": String(describing: result.windowID)
                ]
            )
        } else {
            log(
                "[WindowManager] findStateByFallbackMatching: no match found",
                level: .debug
            )
        }
        return result
    }

    func focusedWindow(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard status == .success, let windowRef else {
            log(
                "[WindowManager] focusedWindow: AX query failed",
                level: .debug,
                fields: [
                    "pid": String(pid),
                    "axStatus": String(status.rawValue)
                ]
            )
            return nil
        }
        return (windowRef as! AXUIElement)
    }

    /// 验证 windowID 对应的窗口是否仍然存在于系统中
    /// 通过 CGWindowList 查询，避免对已销毁窗口的 AX 操作导致 crash
    func validateWindowExists(windowID: UInt32?) -> Bool {
        guard let windowID else { return false }
        log(
            "[WindowManager] validateWindowExists called",
            level: .debug,
            fields: ["windowID": String(windowID)]
        )
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            log(
                "[WindowManager] validateWindowExists: CGWindowList returned nil",
                level: .debug,
                fields: ["windowID": String(windowID)]
            )
            return false
        }
        let exists = windowList.contains { window in
            (window[kCGWindowNumber as String] as? UInt32) == windowID
        }
        log(
            "[WindowManager] validateWindowExists result",
            level: .debug,
            fields: ["windowID": String(windowID), "exists": String(exists)]
        )
        return exists
    }

    func restoreWindow(using token: WindowToken) -> AXUIElement? {
        log(
            "[WindowManager] restoreWindow called",
            level: .debug,
            fields: [
                "stateID": token.stateID,
                "pid": String(token.pid),
                "bundleID": token.bundleIdentifier ?? "nil",
                "windowID": String(describing: token.windowID),
                "title": truncateForLog(token.title ?? "", limit: 60)
            ]
        )
        // 第一级匹配：通过 windowID 匹配当前聚焦窗口
        if let focused = focusedWindow(for: token.pid),
           let currentWindowID = windowHandle(for: focused),
           currentWindowID == token.windowID {
            log("Restoring using focused window handle match")
            return focused
        }

        // 第二级匹配：通过 windowID 匹配缓存的窗口引用（先验证有效性）
        if let lastWindowElement {
            if isValidAXElement(lastWindowElement),
               let currentWindowID = windowHandle(for: lastWindowElement),
               currentWindowID == token.windowID {
                log("Restoring using saved AX handle match")
                return lastWindowElement
            } else {
                // 缓存的 AX 元素已失效，立即清除
                log("Cached AX element is stale, clearing", level: .warn, fields: [
                    "tokenWindowID": String(describing: token.windowID)
                ])
                self.lastWindowElement = nil
                if let stateID = lastWindowToken?.stateID {
                    windowElementsByStateID.removeValue(forKey: stateID)
                }
            }
        }

        // 第二级-B：主动按 PID 遍历所有窗口查找匹配 windowID
        // 这解决了 hook 路径中 hydrateMemory(window:nil) 导致缓存元素过期的问题
        if let resolvedByPID = findWindowByPID(token.pid, windowID: token.windowID) {
            log("Restoring using PID-based window enumeration")
            return resolvedByPID
        }

        // 第三级匹配：备用匹配（PID + 标题 + 大致位置）
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let focused = focusedWindow(for: frontApp.processIdentifier),
           let currentTitle = title(of: focused),
           let currentFrame = frame(of: focused),
           let lastTarget = lastTargetFrame {
            // 检查当前窗口是否匹配 token 的描述
            let pidMatches = frontApp.processIdentifier == token.pid
            let titleMatches = (token.title ?? "") == currentTitle
            let positionMatches = abs(currentFrame.origin.x - lastTarget.origin.x) <= 50 &&
                                 abs(currentFrame.origin.y - lastTarget.origin.y) <= 50

            if pidMatches && titleMatches && positionMatches {
                log("Restoring using fallback matching (PID+title+position)")
                return focused
            }
        }

        log(
            "[WindowManager] restoreWindow: no match found at any level",
            level: .debug,
            fields: [
                "stateID": token.stateID,
                "windowID": String(describing: token.windowID)
            ]
        )
        return nil
    }

    /// 按 PID 遍历应用的所有窗口，查找匹配 windowID 的窗口
    /// 用于 hook 路径中缓存 AX 元素过期时的主动查找
    func findWindowByPID(_ pid: pid_t, windowID: UInt32?) -> AXUIElement? {
        guard let windowID else { return nil }
        log(
            "[WindowManager] findWindowByPID called",
            level: .debug,
            fields: ["pid": String(pid), "windowID": String(windowID)]
        )
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let windows = windowsRef as? [AXUIElement] else {
            log(
                "[WindowManager] findWindowByPID: AX windows query failed",
                level: .debug,
                fields: ["pid": String(pid), "axStatus": String(status.rawValue)]
            )
            return nil
        }
        let found = windows.first { window in
            windowHandle(for: window) == windowID
        }
        log(
            "[WindowManager] findWindowByPID result",
            level: .debug,
            fields: [
                "pid": String(pid),
                "windowID": String(windowID),
                "windowsChecked": String(windows.count),
                "found": String(found != nil)
            ]
        )
        return found
    }

    func shouldRestoreAcrossSpaces() -> Bool {
        spaceController.refreshAvailabilityIfNeeded()
        guard spaceController.isEnabled else {
            log(
                "[WindowManager] shouldRestoreAcrossSpaces: space integration disabled",
                level: .debug
            )
            return false
        }

        let currentSpace = spaceController.currentSpaceIndex()
        guard let candidate = savedWindowStates.last,
              let sourceSpace = candidate.sourceSpaceIndex,
              let current = currentSpace,
              sourceSpace != current else {
            log(
                "[WindowManager] shouldRestoreAcrossSpaces: no cross-space condition met",
                level: .debug,
                fields: [
                    "currentSpace": String(describing: currentSpace),
                    "sourceSpace": String(describing: savedWindowStates.last?.sourceSpaceIndex)
                ]
            )
            return false
        }

        hydrateMemory(from: candidate, window: nil)
        log(
            "[WindowManager] shouldRestoreAcrossSpaces: matched across spaces",
            level: .debug,
            fields: [
                "sourceSpace": String(sourceSpace),
                "currentSpace": String(current)
            ]
        )
        log("Detected moved window state across spaces: source=\(sourceSpace) current=\(current)")
        return true
    }

    func applySpaceStrategyForRestore(windowID: UInt32?, operationID: String? = nil) -> Bool {
        guard let windowID else {
            log(
                "[WindowManager] applySpaceStrategyForRestore: nil windowID, returning true",
                level: .debug
            )
            return true
        }
        let op = operationID ?? makeOperationID(prefix: "restore-space")

        log(
            "[WindowManager] applySpaceStrategyForRestore called",
            level: .debug,
            fields: [
                "op": op,
                "windowID": String(windowID),
                "strategy": SpacePreferences.restoreStrategy.rawValue
            ]
        )

        // 关键安全检查：验证窗口是否仍然存在
        // 如果窗口已被关闭，跳过所有 space 操作以避免 EXC_BAD_ACCESS
        log(
            "[WindowManager] applySpaceStrategyForRestore validating window exists",
            level: .debug,
            fields: ["op": op, "windowID": String(windowID)]
        )
        if !validateWindowExists(windowID: windowID) {
            log(
                "[WindowManager] space strategy aborted: window no longer exists",
                level: .warn,
                fields: [
                    "op": op,
                    "windowID": String(windowID)
                ]
            )
            return true  // 返回 true 表示"不需要 space 操作"，让调用方继续尝试 frame restore
        }

        spaceController.refreshAvailabilityIfNeeded()
        guard spaceController.isEnabled else {
            log(
                "[WindowManager] space strategy skipped: integration disabled",
                fields: [
                    "op": op
                ]
            )
            return true
        }

        log(
            "[WindowManager] applySpaceStrategyForRestore space integration enabled",
            level: .debug,
            fields: ["op": op, "canControlSpaces": String(spaceController.canControlSpaces)]
        )

        guard let currentSpace = spaceController.currentSpaceIndex() else {
            log(
                "[WindowManager] space strategy skipped: current space unavailable",
                level: .warn,
                fields: [
                    "op": op
                ]
            )
            return true
        }

        log(
            "[WindowManager] applySpaceStrategyForRestore resolved currentSpace",
            level: .debug,
            fields: ["op": op, "currentSpace": String(currentSpace)]
        )

        let resolvedSourceSpace = resolveSourceSpaceIndexForRestore()
        log(
            "[WindowManager] applySpaceStrategyForRestore resolvedSourceSpace",
            level: .debug,
            fields: [
                "op": op,
                "resolvedSourceSpace": String(describing: resolvedSourceSpace),
                "lastSourceSpaceIndex": String(describing: lastSourceSpaceIndex)
            ]
        )
        log(
            "[WindowManager] applying space strategy",
            fields: [
                "op": op,
                "strategy": SpacePreferences.restoreStrategy.rawValue,
                "sourceSpace": String(describing: lastSourceSpaceIndex),
                "resolvedSourceSpace": String(describing: resolvedSourceSpace),
                "sourceDisplay": String(describing: lastSourceYabaiDisplayIndex),
                "sourceDisplaySpace": String(describing: lastSourceDisplaySpaceIndex),
                "currentSpace": String(currentSpace),
                "canControlSpaces": String(spaceController.canControlSpaces),
                "windowID": String(windowID)
            ]
        )

        switch SpacePreferences.restoreStrategy {
        case .switchToOriginal:
            log(
                "[WindowManager] applySpaceStrategy using switchToOriginal strategy",
                level: .debug,
                fields: ["op": op]
            )
            guard let sourceSpace = resolvedSourceSpace ?? lastSourceSpaceIndex else {
                log(
                    "[WindowManager] no source space recorded for restore",
                    level: .warn,
                    fields: [
                        "op": op
                    ]
                )
                return true
            }

            guard sourceSpace != currentSpace else {
                log(
                    "[WindowManager] source space equals current space, skip move",
                    fields: [
                        "op": op,
                        "sourceSpace": String(sourceSpace),
                        "currentSpace": String(currentSpace)
                    ]
                )
                return true
            }

            log(
                "[WindowManager] switchToOriginal: sourceSpace != currentSpace, proceeding",
                level: .debug,
                fields: [
                    "op": op,
                    "sourceSpace": String(sourceSpace),
                    "currentSpace": String(currentSpace)
                ]
            )

            guard spaceController.canControlSpaces else {
                log(
                    "[WindowManager] cannot restore to source space: cross-space control unavailable",
                    level: .error,
                    fields: [
                        "op": op,
                        "sourceSpace": String(sourceSpace)
                    ]
                )
                return false
            }

            // === Phase 1: focusSpace 预切换 ===
            // 先切换目标 display 到源 space，确保 space 可见后再移动窗口
            // 这解决了副屏当前显示不同 space 时 AX 坐标被应用到错误 space 的问题

            let preFocusCurrentSpace = currentSpace
            let windowSpaceBefore = spaceController.windowSpaceIndex(windowID: windowID)
            log(
                "[WindowManager] restore_space_pre_focus",
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "sourceSpace": String(sourceSpace),
                    "currentSpaceAtEntry": String(preFocusCurrentSpace),
                    "windowActualSpace": String(describing: windowSpaceBefore),
                    "sourceYabaiDisplay": String(describing: lastSourceYabaiDisplayIndex),
                    "sourceDisplaySpace": String(describing: lastSourceDisplaySpaceIndex)
                ]
            )

            let focusStartedAt = Date()
            let focusSucceeded = spaceController.focusSpace(sourceSpace, operationID: op)
            let focusDurationMs = elapsedMilliseconds(since: focusStartedAt)
            log(
                "[WindowManager] switchToOriginal focusSpace returned",
                level: .debug,
                fields: [
                    "op": op,
                    "focusSucceeded": String(focusSucceeded),
                    "focusDurationMs": String(focusDurationMs)
                ]
            )
            let postFocusSpace = spaceController.currentSpaceIndex()

            log(
                "[WindowManager] restore_space_post_focus",
                fields: [
                    "op": op,
                    "focusSucceeded": String(focusSucceeded),
                    "focusDurationMs": String(focusDurationMs),
                    "targetSpace": String(sourceSpace),
                    "actualCurrentSpace": String(describing: postFocusSpace),
                    "spaceChanged": String(postFocusSpace != preFocusCurrentSpace)
                ]
            )

            if focusSucceeded {
                // 仅在 space 实际切换时等待动画完成
                if postFocusSpace != preFocusCurrentSpace {
                    usleep(150_000)
                }

                let postSettleSpace = spaceController.currentSpaceIndex()
                log(
                    "[WindowManager] restore_space_post_settle",
                    fields: [
                        "op": op,
                        "targetSpace": String(sourceSpace),
                        "actualCurrentSpace": String(describing: postSettleSpace),
                        "settleOk": String(postSettleSpace == sourceSpace),
                        "spaceChanged": String(postFocusSpace != preFocusCurrentSpace)
                    ]
                )
            } else {
                log(
                    "[WindowManager] restore_space_focus_failed_continuing",
                    level: .warn,
                    fields: [
                        "op": op,
                        "targetSpace": String(sourceSpace),
                        "focusDurationMs": String(focusDurationMs)
                    ]
                )
                // focusSpace 失败可能把 canControlSpaces 污染为 false（scripting-addition 错误）
                // 刷新可用性状态，让 moveWindow 仍有机会执行
                spaceController.refreshAvailability(force: true)
                log(
                    "[WindowManager] restore_space_post_focus_recovery",
                    fields: [
                        "op": op,
                        "canControlSpaces": String(spaceController.canControlSpaces)
                    ]
                )
            }

            // === Phase 2: moveWindow ===
            log(
                "[WindowManager] switchToOriginal Phase 2: calling moveWindow",
                level: .debug,
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "targetSpace": String(sourceSpace)
                ]
            )
            if spaceController.moveWindow(windowID, toSpaceIndex: sourceSpace, focus: false, operationID: op) {
                let windowSpaceAfterMove = spaceController.windowSpaceIndex(windowID: windowID)
                log(
                    "[WindowManager] restore_space_post_move",
                    fields: [
                        "op": op,
                        "windowID": String(windowID),
                        "targetSpace": String(sourceSpace),
                        "windowActualSpace": String(describing: windowSpaceAfterMove),
                        "moveVerified": String(windowSpaceAfterMove == sourceSpace)
                    ]
                )
                if !spaceController.focusWindow(windowID, operationID: op) {
                    log(
                        "[WindowManager] failed to focus restored window on source space",
                        level: .warn,
                        fields: [
                            "op": op,
                            "windowID": String(windowID),
                            "space": String(sourceSpace)
                        ]
                    )
                } else {
                    log(
                        "[WindowManager] switchToOriginal focusWindow succeeded on source space",
                        level: .debug,
                        fields: ["op": op, "windowID": String(windowID)]
                    )
                }
            } else {
                log(
                    "[WindowManager] restore_space_move_failed",
                    level: .error,
                    fields: [
                        "op": op,
                        "windowID": String(windowID),
                        "targetSpace": String(sourceSpace)
                    ]
                )
                return false
            }

            log(
                "[WindowManager] restore_space_result",
                fields: [
                    "op": op,
                    "outcome": "success",
                    "sourceSpace": String(sourceSpace),
                    "focusOk": String(focusSucceeded),
                    "focusDurationMs": String(focusDurationMs)
                ]
            )
            return true
        case .pullToCurrent:
            log(
                "[WindowManager] applySpaceStrategy using pullToCurrent strategy",
                level: .debug,
                fields: [
                    "op": op,
                    "currentSpace": String(currentSpace),
                    "lastSourceSpaceIndex": String(describing: lastSourceSpaceIndex)
                ]
            )
            if let sourceSpace = lastSourceSpaceIndex, sourceSpace != currentSpace {
                log(
                    "[WindowManager] pullToCurrent: sourceSpace != currentSpace, need to move",
                    level: .debug,
                    fields: [
                        "op": op,
                        "sourceSpace": String(sourceSpace),
                        "currentSpace": String(currentSpace)
                    ]
                )
                guard spaceController.canControlSpaces else {
                    log(
                        "[WindowManager] cannot pull window: cross-space control unavailable",
                        level: .error,
                        fields: [
                            "op": op,
                            "sourceSpace": String(sourceSpace),
                            "currentSpace": String(currentSpace)
                        ]
                    )
                    return false
                }

                if spaceController.moveWindow(windowID, toSpaceIndex: currentSpace, focus: false, operationID: op) {
                    log(
                        "[WindowManager] moved window to current space for restore",
                        fields: [
                            "op": op,
                            "windowID": String(windowID),
                            "space": String(currentSpace)
                        ]
                    )
                    if !spaceController.focusWindow(windowID, operationID: op) {
                        log(
                            "[WindowManager] pullToCurrent focusWindow failed",
                            level: .debug,
                            fields: ["op": op, "windowID": String(windowID)]
                        )
                        log(
                            "[WindowManager] failed to focus restored window on current space",
                            level: .warn,
                            fields: [
                                "op": op,
                                "windowID": String(windowID),
                                "space": String(currentSpace)
                            ]
                        )
                    }
                } else {
                    log(
                        "[WindowManager] failed to move window to current space",
                        level: .error,
                        fields: [
                            "op": op,
                            "windowID": String(windowID),
                            "space": String(currentSpace)
                        ]
                    )
                    return false
                }
            }
            return true
        }
    }

    private func resolveSourceSpaceIndexForRestore() -> Int? {
        log(
            "[WindowManager] resolveSourceSpaceIndexForRestore called",
            level: .debug,
            fields: [
                "lastSourceYabaiDisplayIndex": String(describing: lastSourceYabaiDisplayIndex),
                "lastSourceDisplaySpaceIndex": String(describing: lastSourceDisplaySpaceIndex),
                "lastSourceSpaceIndex": String(describing: lastSourceSpaceIndex)
            ]
        )
        guard let displayIndex = lastSourceYabaiDisplayIndex,
              let displaySpaceIndex = lastSourceDisplaySpaceIndex else {
            return lastSourceSpaceIndex
        }

        guard let mapped = spaceController.globalSpaceIndex(
            displayIndex: displayIndex,
            localSpaceIndex: displaySpaceIndex
        ) else {
            log("resolveSourceSpaceIndexForRestore: failed to map display-local space (display=\(displayIndex), local=\(displaySpaceIndex)); fallback to source=\(String(describing: lastSourceSpaceIndex))")
            return lastSourceSpaceIndex
        }

        if mapped != lastSourceSpaceIndex {
            log("resolveSourceSpaceIndexForRestore: remapped source from \(String(describing: lastSourceSpaceIndex)) to \(mapped) using display=\(displayIndex) local=\(displaySpaceIndex)")
        }
        return mapped
    }

}
