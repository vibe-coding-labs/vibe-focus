// WindowManager+Toggle+Decision.swift
// VibeFocus — Toggle restore 决策逻辑
// 从 WindowManager+Toggle.swift 中提取

import AppKit
import Foundation

@MainActor
extension WindowManager {

    /// Restore decision — extracted for testability
    enum RestoreDecision {
        case restore                // window on main + valid toggle record
        case moveToMain             // window on secondary screen
        case noRecord               // no toggle record found
        case corruptedClearWindowID(UInt32)  // record exists but invalid
        case noFocusedWindow        // cannot identify focused window
        case noMainScreen           // cannot get main screen frame
    }

    /// Pure decision logic for shouldRestoreCurrentWindow.
    /// Separates the decision tree from system I/O for unit testing.
    static func decideRestore(
        focusedOnMain: Bool?,
        recordByWindowID: ToggleRecord?,
        mainScreenFrame: CGRect?
    ) -> RestoreDecision {
        guard let focusedOnMain else {
            return .noFocusedWindow
        }
        if !focusedOnMain {
            return .moveToMain
        }
        guard let record = recordByWindowID else {
            return .noRecord
        }
        guard let mainScreenFrame else {
            return .noMainScreen
        }
        if !record.isValid(mainScreenFrame: mainScreenFrame) {
            return .corruptedClearWindowID(record.windowID)
        }
        return .restore
    }

    func shouldRestoreCurrentWindow() -> Bool {
        return shouldRestoreCurrentWindow(store: ToggleEngine.shared)
    }

    /// Testable overload that accepts an injected ToggleRecordStore.
    func shouldRestoreCurrentWindow(store: ToggleRecordStore) -> Bool {
        if !hasAccessibilityPermission() {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: no AX permission, cannot determine",
                level: .debug
            )
            return false
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let focusedWindow = focusedWindow(for: frontApp.processIdentifier),
              let currentWindowID = windowHandle(for: focusedWindow) else {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: cannot identify focused window",
                level: .debug,
                fields: [
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
                "focusedOnMainScreen": String(focusedOnMain)
            ]
        )

        if !focusedOnMain {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: focused window on secondary screen → move to main",
                fields: ["windowID": String(currentWindowID)]
            )
            return false
        }

        // 聚焦窗口在主屏 → 直接查 SQLite 看有没有 toggle record
        guard let record = store.load(windowID: currentWindowID) else {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: no toggle record for window",
                level: .debug,
                fields: ["windowID": String(currentWindowID)]
            )
            return false
        }

        guard let mainScreen = getMainScreen() else { return false }
        if !record.isValid(mainScreenFrame: mainScreen.frame) {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: toggle record corrupted, clearing",
                level: .warn,
                fields: [
                    "windowID": String(currentWindowID),
                    "storedWindowID": String(record.windowID)
                ]
            )
            store.clear(windowID: record.windowID)
            return false
        }

        // isNearTarget 守卫已移除 — yabai tiling 引擎会移动窗口导致偏移，
        // 此时恰恰是需要 restore 的场景。isValid 检查已足够防止 corrupted data。

        log(
            "[WindowManager] shouldRestoreCurrentWindow: focused window on main, has valid toggle record → restore",
            fields: [
                "windowID": String(currentWindowID),
                "pid": String(record.pid)
            ]
        )
        return true
    }
}
