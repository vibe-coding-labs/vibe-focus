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
    /// 标记 focusSpace 是否在本次 app 生命周期内无效（yabai SA 不可用导致）
    var focusSpaceKnownBroken: Bool = false
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
            log("Loaded persisted window states from SQLite: \(savedWindowStates.count)")
        }
        cleanupStaleStatesWithGracePeriod()
    }

    /// 启动时清理 grace period 之外的无效 state
    /// grace period = 5 分钟：state 保存时间超过 5 分钟且 window 已不存在才删除
    /// 防止 app 短暂重启期间误删仍在使用的 state
    private func cleanupStaleStatesWithGracePeriod() {
        let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let existingWindowIDs = Set(windowList.compactMap { $0["kCGWindowNumber"] as? UInt32 })

        let gracePeriod: TimeInterval = 5 * 60
        let removed = WindowStateStore.shared.cleanupStaleStates(
            existingWindowIDs: existingWindowIDs,
            gracePeriod: gracePeriod
        )

        if removed > 0 {
            savedWindowStates.removeAll { state in
                guard let wid = state.windowID else { return false }
                return !existingWindowIDs.contains(wid)
            }
            log("[WindowManager] cleanup with grace period: removed \(removed) stale state(s)")
        }
    }

    func getCurrentWindowFrame(windowID: UInt32) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for w in list {
            if let wid = w["kCGWindowNumber"] as? UInt32, wid == windowID {
                if let b = w["kCGWindowBounds"] as? [String: Double] {
                    return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
                }
            }
        }
        return nil
    }

    func toggle(operationID: String? = nil, triggerSource: String = "unknown") {
        let op = operationID ?? makeOperationID(prefix: "toggle")
        let startedAt = Date()
        let frontBefore = frontmostAppDescriptor()
        updateCrashSnapshotFromRuntime()
        logRuntimeStateSnapshot(context: "toggle_start")

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
            // 移动窗口后 macOS 可能丢失焦点，重新 focus 被移动的窗口
            _ = spaceController.focusWindow(identity.windowID, operationID: op)
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
        updateCrashSnapshotFromRuntime()
        logRuntimeStateSnapshot(context: "restore_start")

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

        // === 两阶段恢复：先移窗口到副屏，再切到正确 Space ===
        log(
            "[WindowManager] restore: preparing space correction",
            level: .info,
            fields: [
                "op": op,
                "sourceSpaceIndex": String(describing: lastSourceSpaceIndex),
                "sourceYabaiDisplayIndex": String(describing: lastSourceYabaiDisplayIndex),
                "triggerSource": triggerSource
            ]
        )
        let spacePrepared = true

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

        // === Space 切换：在 apply frame 之前确保目标 display 显示正确的 Space ===
        // 逻辑：1) 查目标 display 当前显示什么 space  2) 如果不是目标 space，先用 yabai 切换  3) 然后再 apply frame
        if triggerSource == "carbon_hotkey", let targetSpace = lastSourceSpaceIndex {
            let targetDisplay = lastSourceYabaiDisplayIndex
            let displayCurrentSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)

            log("[WindowManager] restore: pre-apply space check", fields: [
                "op": op,
                "targetSpace": String(targetSpace),
                "targetDisplay": String(describing: targetDisplay),
                "displayCurrentSpace": String(describing: displayCurrentSpace)
            ])

            if let current = displayCurrentSpace, current != targetSpace {
                log("[WindowManager] restore: switching display from space \(current) to \(targetSpace)", level: .info, fields: [
                    "op": op, "targetDisplay": String(describing: targetDisplay)
                ])

                let switched = spaceController.switchDisplayToSpace(targetSpace: targetSpace, operationID: op)
                if switched {
                    usleep(400_000)
                }
                log("[WindowManager] restore: space switch result", fields: [
                    "op": op, "switched": String(switched)
                ])
            } else {
                log("[WindowManager] restore: display already on target space, no switch needed", fields: [
                    "op": op
                ])
            }
        }

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

        // === Space 状态验证（post-apply） ===
        if let windowID = windowHandle(for: window) {
            let postApplySpace = spaceController.windowSpaceIndex(windowID: windowID)
            log("[WindowManager] restore: post-apply space state", fields: [
                "op": op,
                "targetSpace": String(describing: lastSourceSpaceIndex),
                "actualSpace": String(describing: postApplySpace)
            ])

            // toggle 热键恢复时跟随窗口焦点
            if triggerSource == "carbon_hotkey" {
                let currentSpace = spaceController.currentSpaceIndex()
                if let ws = postApplySpace, let cs = currentSpace, ws != cs {
                    log("[WindowManager] restore: following window to Space \(ws)", fields: [
                        "op": op, "windowID": String(windowID), "currentSpace": String(cs)
                    ])
                    _ = spaceController.focusWindow(windowID, operationID: op)
                }
            }
        }

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
            fields: [
                "savedStatesCount": String(savedWindowStates.count),
                "hasActiveToken": String(lastWindowToken != nil),
                "hasActiveFrame": String(lastWindowFrame != nil)
            ]
        )
        if !hasAccessibilityPermission() {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: no AX permission, using System Events",
                level: .debug
            )
            return shouldRestoreCurrentWindowViaSystemEvents()
        }

        // 核心原则：以当前聚焦窗口为决策依据，而非全局状态
        // 用户按热键的意图由"当前聚焦窗口在哪里"决定：
        //   - 聚焦窗口在副屏 → move to main
        //   - 聚焦窗口在主屏且有 saved state → restore 回副屏
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let focusedWindow = focusedWindow(for: frontApp.processIdentifier),
              let currentWindowID = windowHandle(for: focusedWindow) else {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: cannot identify focused window",
                level: .debug,
                fields: [
                    "savedStatesEmpty": String(savedWindowStates.isEmpty),
                    "hasFrontApp": String(NSWorkspace.shared.frontmostApplication != nil)
                ]
            )
            return false
        }

        let focusedOnMain = isWindowOnMainScreen(windowID: currentWindowID)
        log(
            "[WindowManager] shouldRestoreCurrentWindow: focused window identified",
            level: .debug,
            fields: [
                "focusedWindowID": String(currentWindowID),
                "focusedOnMainScreen": String(focusedOnMain),
                "savedStatesCount": String(savedWindowStates.count)
            ]
        )

        if !focusedOnMain {
            // 聚焦窗口在副屏 → 用户想把它移到主屏
            log(
                "[WindowManager] shouldRestoreCurrentWindow: focused window on secondary screen → move to main",
                fields: ["windowID": String(currentWindowID)]
            )
            return false
        }

        // 聚焦窗口在主屏 → 检查 WindowState 中是否有 toggle state 可以恢复
        if let wsState = SessionWindowRegistry.shared.findState(windowID: currentWindowID) {
            if wsState.hasToggleState {
                guard let mainScreen = getMainScreen() else { return false }
                if wsState.isCorrupted(mainScreenFrame: mainScreen.frame) {
                    SessionWindowRegistry.shared.clearToggleState(windowID: wsState.windowID)
                    return false
                }
                if let origFrame = wsState.originalFrame, let tgtFrame = wsState.targetFrame {
                    // 验证窗口确实在 targetFrame 附近（被 toggle 到的位置）
                    let currentFrame = self.frame(of: focusedWindow)
                    if let curFrame = currentFrame, !wsState.isNearTarget(currentFrame: curFrame) {
                        log(
                            "[WindowManager] shouldRestoreCurrentWindow: window not at target position curX=\(curFrame.origin.x) curY=\(curFrame.origin.y) tgtX=\(tgtFrame.origin.x) tgtY=\(tgtFrame.origin.y)",
                            level: .warn,
                            fields: ["windowID": "\(currentWindowID)"]
                        )
                        return false
                    }
                    let savedState = SavedWindowState(
                        id: "\(wsState.pid)_\(wsState.tty ?? "none")",
                        pid: wsState.pid,
                        bundleIdentifier: wsState.bundleIdentifier,
                        appName: wsState.appName,
                        windowID: wsState.windowID,
                        windowNumber: wsState.axWindowNumber,
                        title: wsState.title,
                        originalFrame: RectPayload(origFrame),
                        targetFrame: RectPayload(tgtFrame),
                        sourceSpaceIndex: wsState.sourceSpace,
                        targetSpaceIndex: nil,
                        sourceYabaiDisplayIndex: wsState.sourceYabaiDisp,
                        sourceDisplaySpaceIndex: wsState.sourceDispSpace,
                        sourceDisplayIndex: wsState.sourceDisplay,
                        sourceDisplayID: nil,
                        targetDisplayIndex: wsState.targetDisplay,
                        restoreReason: wsState.toggleReason,
                        sessionID: wsState.sessionID,
                        savedAt: wsState.toggledAt ?? Date()
                    )
                    hydrateMemory(from: savedState, window: focusedWindow)
                    log(
                        "[WindowManager] shouldRestoreCurrentWindow: focused window on main, has toggle state → restore",
                        fields: [
                            "windowID": String(currentWindowID),
                            "pid": String(wsState.pid),
                            "tty": wsState.tty ?? "nil"
                        ]
                    )
                    return true
                }
            }
        }

        log(
            "[WindowManager] shouldRestoreCurrentWindow: focused window on main but no matching toggle state",
            level: .debug,
            fields: ["windowID": String(currentWindowID)]
        )
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
        return unsafeBitCast(windowRef, to: AXUIElement.self)
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

    func applySpaceStrategyForRestore(windowID: UInt32?, operationID: String? = nil, triggerSource: String = "unknown") -> Bool {
        guard let windowID else {
            log(
                "[WindowManager] applySpaceStrategyForRestore: nil windowID, returning true",
                level: .debug
            )
            return true
        }
        let op = operationID ?? makeOperationID(prefix: "restore-space")

        // 注意：focusSpaceKnownBroken 时不能跳过整个 Space 策略！
        // 只跳过 yabai focusSpace（已知失败），但 NativeSpaceBridge.moveWindow + focusWindow 仍需执行
        // 否则用户活跃 Space 不会切换，窗口虽然在正确坐标但用户看不到

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
            // 如果上次 focusSpace 已确认无效（yabai SA 不可用），直接跳过
            let focusSucceeded: Bool
            if focusSpaceKnownBroken {
                log(
                    "[WindowManager] switchToOriginal skipping focusSpace (known broken)",
                    level: .debug,
                    fields: ["op": op]
                )
                focusSucceeded = false
            } else {
                focusSucceeded = spaceController.focusSpace(sourceSpace, operationID: op)
            }
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

            // 如果 focusSpace "成功"但 Space 没变，标记为 broken 避免下次浪费时间
            if focusSucceeded && postFocusSpace == preFocusCurrentSpace {
                focusSpaceKnownBroken = true
                log(
                    "[WindowManager] focusSpace reported success but space unchanged, marking as broken",
                    level: .warn,
                    fields: ["op": op, "focusDurationMs": String(focusDurationMs)]
                )
            }

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
                // 仅在 space 实际切换且到达目标时等待动画完成
                if postFocusSpace != preFocusCurrentSpace && postFocusSpace == sourceSpace {
                    usleep(80_000)
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
                // 不强制刷新（太慢），直接让 moveWindow 尝试执行
                log(
                    "[WindowManager] restore_space_post_focus_recovery",
                    fields: [
                        "op": op,
                        "canControlSpaces": String(spaceController.canControlSpaces)
                    ]
                )
            }

            // === Phase 2: moveWindow ===
            // 即使 focusSpace 失败，moveWindow 仍需执行（NativeSpaceBridge 不需要 SA）
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
                if triggerSource == "carbon_hotkey" {
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
                        "[WindowManager] switchToOriginal skipping focusWindow (hook-restore)",
                        level: .debug,
                        fields: ["op": op, "windowID": String(windowID), "triggerSource": triggerSource]
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
                // moveWindow 失败也标记 focusSpace broken，下次优化路径
                focusSpaceKnownBroken = true
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
                    if triggerSource == "carbon_hotkey" {
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
                            "[WindowManager] pullToCurrent skipping focusWindow (hook-restore)",
                            level: .debug,
                            fields: ["op": op, "windowID": String(windowID), "triggerSource": triggerSource]
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
