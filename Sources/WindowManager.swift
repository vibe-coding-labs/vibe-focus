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
    }

    func toggle() {
        log("[WindowManager] toggle() called")
        let shouldRestore = shouldRestoreCurrentWindow()
        log("[WindowManager] shouldRestoreCurrentWindow() = \(shouldRestore)")
        if shouldRestore {
            restore()
        } else {
            moveToMainScreen()
        }
    }

    func moveToMainScreen() {
        log("[WindowManager] === MOVE TO MAIN SCREEN ===")
        let startTime = Date()
        let axTrusted = hasAccessibilityPermission()
        log("[WindowManager] AX trusted = \(axTrusted)")

        if !axTrusted {
            logDiagnostics("ax_trusted_false_move")
            moveToMainScreenViaSystemEvents()
            return
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            log("No frontmost app")
            return
        }

        guard let windowAX = focusedWindow(for: frontApp.processIdentifier) else {
            log("Cannot get focused window")
            return
        }

        let windowNumber = windowNumber(for: windowAX)
        if windowNumber == nil {
            log("Window number unavailable; will use direct AX reference fallback")
        }
        let windowTitle = title(of: windowAX)
        let bundleIdentifier = frontApp.bundleIdentifier
        let appName = frontApp.localizedName

        guard let currentFrame = frame(of: windowAX) else {
            log("Cannot get current frame")
            return
        }

        guard let currentWindowID = windowHandle(for: windowAX) else {
            log("Cannot get stable window handle for focused window")
            return
        }

        let spaceContext = spaceController.captureSpaceContext(windowID: currentWindowID)

        guard isAttributeSettable(windowAX, attribute: kAXPositionAttribute) else {
            log("Window position is not settable")
            return
        }

        guard isAttributeSettable(windowAX, attribute: kAXSizeAttribute) else {
            log("Window size is not settable")
            return
        }

        guard let mainScreen = getMainScreen() else {
            log("Cannot get main screen")
            return
        }

        let targetFrame = axFrame(forVisibleFrameOf: mainScreen)
        log("Current window: pid=\(frontApp.processIdentifier), number=\(String(describing: windowNumber)), title=\(windowTitle ?? "nil"), frame=\(currentFrame)")
        log("Target screen visible frame: \(mainScreen.visibleFrame)")
        log("Target AX frame: \(targetFrame)")

        AXUIElementPerformAction(windowAX, kAXRaiseAction as CFString)

        guard apply(frame: targetFrame, to: windowAX) else {
            log("❌ MOVE FAILED")
            return
        }

        guard let appliedFrame = frame(of: windowAX) else {
            log("❌ MOVE FAILED: cannot read back frame")
            return
        }

        log("Applied frame: \(appliedFrame)")

        guard framesMatch(appliedFrame, targetFrame) else {
            log("❌ MOVE FAILED: verification mismatch")
            return
        }

        let savedState = SavedWindowState(
            id: UUID().uuidString,
            pid: frontApp.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowID: currentWindowID,
            windowNumber: windowNumber,
            title: windowTitle,
            originalFrame: RectPayload(currentFrame),
            targetFrame: RectPayload(targetFrame),
            sourceSpaceIndex: spaceContext.sourceSpaceIndex,
            targetSpaceIndex: spaceContext.targetSpaceIndex,
            savedAt: Date()
        )

        let persistedState = saveWindowState(savedState, window: windowAX)
        hydrateMemory(from: persistedState, window: windowAX)
        let elapsed = Date().timeIntervalSince(startTime)
        log("[WindowManager] ✅ MOVED AND MAXIMIZED ON TARGET SCREEN (took \(String(format: "%.3f", elapsed))s)")
    }

    func restore() {
        log("[WindowManager] === RESTORE ===")
        let startTime = Date()

        if !hasAccessibilityPermission() {
            log("[WindowManager] No accessibility permission, using SystemEvents fallback")
            restoreViaSystemEvents()
            return
        }

        if lastWindowToken == nil || lastWindowFrame == nil || lastTargetFrame == nil {
            log("[WindowManager] No active memory state, checking saved states")
            if shouldRestoreCurrentWindow() == false {
                log("[WindowManager] No saved window to restore")
                return
            }
        }

        guard let token = lastWindowToken, let frame = lastWindowFrame else {
            log("[WindowManager] No active window state to restore")
            return
        }

        log("[WindowManager] Restoring window: pid=\(token.pid), windowID=\(String(describing: token.windowID))")

        applySpaceStrategyForRestore(windowID: token.windowID)

        guard let window = restoreWindow(using: token) else {
            log("[WindowManager] ❌ Window not found")
            return
        }

        guard isAttributeSettable(window, attribute: kAXPositionAttribute) else {
            log("[WindowManager] ❌ Window position is not settable")
            return
        }

        guard isAttributeSettable(window, attribute: kAXSizeAttribute) else {
            log("[WindowManager] ❌ Window size is not settable")
            return
        }

        log("[WindowManager] Restoring to frame: \(frame)")

        guard apply(frame: frame, to: window) else {
            log("[WindowManager] ❌ RESTORE FAILED: apply() returned false")
            return
        }

        guard let restoredFrame = self.frame(of: window) else {
            log("[WindowManager] ❌ RESTORE FAILED: cannot read back frame")
            return
        }

        log("[WindowManager] Restored frame: \(restoredFrame)")

        guard framesMatch(restoredFrame, frame) else {
            log("[WindowManager] ❌ RESTORE FAILED: verification mismatch")
            return
        }

        resetActiveWindowContext(removeState: true)
        let elapsed = Date().timeIntervalSince(startTime)
        log("[WindowManager] ✅ RESTORED (took \(String(format: "%.3f", elapsed))s)")
    }

    func getMainScreen() -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            if let value = screen.deviceDescription[key] as? NSNumber,
               CGDirectDisplayID(value.uint32Value) == mainDisplayID {
                return screen
            }
        }
        return NSScreen.screens.first ?? NSScreen.main
    }

    func hasAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func notifyAccessibilityPermissionRequired() {
        guard !didPromptForAccessibility else {
            return
        }

        didPromptForAccessibility = true
        NSSound.beep()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func shouldRestoreCurrentWindow() -> Bool {
        log("[WindowManager] shouldRestoreCurrentWindow() called")
        log("[WindowManager] savedWindowStates.count = \(savedWindowStates.count)")

        if !hasAccessibilityPermission() {
            log("[WindowManager] No accessibility permission, using SystemEvents fallback")
            return shouldRestoreCurrentWindowViaSystemEvents()
        }

        guard !savedWindowStates.isEmpty,
              let frontApp = NSWorkspace.shared.frontmostApplication,
              let focusedWindow = focusedWindow(for: frontApp.processIdentifier),
              let currentWindowID = windowHandle(for: focusedWindow) else {
            log("[WindowManager] No saved states or cannot get window, checking across spaces")
            let result = shouldRestoreAcrossSpaces()
            log("[WindowManager] shouldRestoreAcrossSpaces() = \(result)")
            return result
        }

        log("[WindowManager] Checking window: pid=\(frontApp.processIdentifier), windowID=\(currentWindowID)")

        // 第一级匹配：通过 windowID（最可靠的方式）
        if let matchedState = savedWindowStates.reversed().first(where: { $0.windowID == currentWindowID }) {
            hydrateMemory(from: matchedState, window: focusedWindow)
            log("[WindowManager] ✓ Found match by windowID: \(currentWindowID)")
            return true
        }
        log("[WindowManager] ✗ No match by windowID")

        // 第二级匹配：通过 PID + 窗口标题 + 大致位置（备用机制）
        if let currentFrame = frame(of: focusedWindow),
           let currentTitle = title(of: focusedWindow),
           let matchedState = findStateByFallbackMatching(
               pid: frontApp.processIdentifier,
               title: currentTitle,
               frame: currentFrame,
               windowID: currentWindowID
           ) {
            hydrateMemory(from: matchedState, window: focusedWindow)
            log("[WindowManager] ✓ Found match by fallback (PID+title+position)")
            return true
        }
        log("[WindowManager] ✗ No match by fallback")

        let result = shouldRestoreAcrossSpaces()
        log("[WindowManager] shouldRestoreAcrossSpaces() = \(result)")
        return result
    }

    /// 备用匹配机制：当 windowID 匹配失败时使用
    /// 基于 PID + 窗口标题 + 大致位置进行匹配
    private func findStateByFallbackMatching(
        pid: pid_t,
        title: String,
        frame: CGRect,
        windowID: UInt32
    ) -> SavedWindowState? {
        // 匹配条件：
        // 1. PID 相同
        // 2. 窗口标题相同（或都为空）
        // 3. 当前位置接近保存的 targetFrame（因为窗口已经被移动过）

        let positionTolerance: CGFloat = 50.0  // 位置容差 50 像素

        return savedWindowStates.reversed().first { state in
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
    }

    func focusedWindow(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard status == .success, let windowRef else {
            return nil
        }
        return (windowRef as! AXUIElement)
    }

    func restoreWindow(using token: WindowToken) -> AXUIElement? {
        // 第一级匹配：通过 windowID 匹配当前聚焦窗口
        if let focused = focusedWindow(for: token.pid),
           let currentWindowID = windowHandle(for: focused),
           currentWindowID == token.windowID {
            log("Restoring using focused window handle match")
            return focused
        }

        // 第二级匹配：通过 windowID 匹配缓存的窗口引用
        if let lastWindowElement,
           let currentWindowID = windowHandle(for: lastWindowElement),
           currentWindowID == token.windowID {
            log("Restoring using saved AX handle match")
            return lastWindowElement
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

        return nil
    }

    func shouldRestoreAcrossSpaces() -> Bool {
        // 不要在这里调用 refreshAvailabilityIfNeeded()，避免阻塞
        // 依赖 spaceController 已有的状态
        guard spaceController.isEnabled else {
            return false
        }

        guard let currentSpace = spaceController.currentSpaceIndex(),
              let candidate = savedWindowStates.last,
              let sourceSpace = candidate.sourceSpaceIndex,
              sourceSpace != currentSpace else {
            return false
        }

        hydrateMemory(from: candidate, window: nil)
        log("Detected moved window state across spaces: source=\(sourceSpace) current=\(currentSpace)")
        return true
    }

    func applySpaceStrategyForRestore(windowID: UInt32?) {
        guard let windowID else { return }

        spaceController.refreshAvailabilityIfNeeded()
        guard spaceController.isEnabled else {
            return
        }

        guard let currentSpace = spaceController.currentSpaceIndex() else {
            return
        }

        switch SpacePreferences.restoreStrategy {
        case .switchToOriginal:
            if let sourceSpace = lastSourceSpaceIndex, sourceSpace != currentSpace {
                if spaceController.focusSpace(sourceSpace) {
                    log("Focused space \(sourceSpace) for restore")
                } else {
                    log("Failed to focus space \(sourceSpace) for restore")
                }
            }
            _ = spaceController.focusWindow(windowID)
        case .pullToCurrent:
            if let sourceSpace = lastSourceSpaceIndex, sourceSpace != currentSpace {
                if spaceController.moveWindow(windowID, toSpaceIndex: currentSpace, focus: true) {
                    log("Moved window to current space \(currentSpace) for restore")
                } else {
                    log("Failed to move window to current space \(currentSpace)")
                }
            } else {
                _ = spaceController.focusWindow(windowID)
            }
        }
    }

}
