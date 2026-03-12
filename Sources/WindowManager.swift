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
    var windowElementsByStateID: [String: AXUIElement] = [:]
    var lastWindowElement: AXUIElement?
    var lastWindowToken: WindowToken?
    var lastWindowFrame: CGRect?
    var lastTargetFrame: CGRect?
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
        if shouldRestoreCurrentWindow() {
            restore()
        } else {
            moveToMainScreen()
        }
    }

    func moveToMainScreen() {
        log("=== MOVE TO MAIN SCREEN ===")
        let axTrusted = hasAccessibilityPermission()
        log("AX trusted = \(axTrusted)")

        if !axTrusted {
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
            savedAt: Date()
        )

        let persistedState = saveWindowState(savedState, window: windowAX)
        hydrateMemory(from: persistedState, window: windowAX)
        log("✅ MOVED AND MAXIMIZED ON TARGET SCREEN")
    }

    func restore() {
        log("=== RESTORE ===")

        if !hasAccessibilityPermission() {
            restoreViaSystemEvents()
            return
        }

        if lastWindowToken == nil || lastWindowFrame == nil || lastTargetFrame == nil {
            if shouldRestoreCurrentWindow() == false {
                log("No saved window to restore")
                return
            }
        }

        guard let token = lastWindowToken, let frame = lastWindowFrame else {
            log("No active window state to restore")
            return
        }

        guard let window = restoreWindow(using: token) else {
            log("Window not found")
            return
        }

        guard isAttributeSettable(window, attribute: kAXPositionAttribute) else {
            log("Window position is not settable")
            return
        }

        guard isAttributeSettable(window, attribute: kAXSizeAttribute) else {
            log("Window size is not settable")
            return
        }

        log("Restoring to: \(frame)")

        guard apply(frame: frame, to: window) else {
            log("❌ RESTORE FAILED")
            return
        }

        guard let restoredFrame = self.frame(of: window) else {
            log("❌ RESTORE FAILED: cannot read back frame")
            return
        }

        log("Restored frame: \(restoredFrame)")

        guard framesMatch(restoredFrame, frame) else {
            log("❌ RESTORE FAILED: verification mismatch")
            return
        }

        resetActiveWindowContext(removeState: true)
        log("✅ RESTORED")
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
        if !hasAccessibilityPermission() {
            return shouldRestoreCurrentWindowViaSystemEvents()
        }

        guard !savedWindowStates.isEmpty,
              let frontApp = NSWorkspace.shared.frontmostApplication,
              let focusedWindow = focusedWindow(for: frontApp.processIdentifier),
              let currentWindowID = windowHandle(for: focusedWindow) else {
            return false
        }

        guard let matchedState = savedWindowStates.reversed().first(where: { $0.windowID == currentWindowID }) else {
            return false
        }

        hydrateMemory(from: matchedState, window: focusedWindow)
        log("Detected moved window state for current handle: \(currentWindowID)")
        return true
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
        if let focused = focusedWindow(for: token.pid),
           let currentWindowID = windowHandle(for: focused),
           currentWindowID == token.windowID {
            log("Restoring using focused window handle match")
            return focused
        }

        if let lastWindowElement,
           let currentWindowID = windowHandle(for: lastWindowElement),
           currentWindowID == token.windowID {
            log("Restoring using saved AX handle match")
            return lastWindowElement
        }

        return nil
    }

}
