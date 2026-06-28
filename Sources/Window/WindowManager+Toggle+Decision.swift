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
        return shouldRestoreCurrentWindow(windowID: nil, store: ToggleEngine.shared)
    }

    /// Testable overload that accepts an injected ToggleRecordStore.
    /// 不带 windowID → 走旧 AX 查询路径（测试 / 非 toggle 入口兼容）。
    func shouldRestoreCurrentWindow(store: ToggleRecordStore) -> Bool {
        return shouldRestoreCurrentWindow(windowID: nil, store: store)
    }

    /// 主实现：优先用 toggle 入口已解析的 windowID（来自 CGWindowList 快照），
    /// 避免再次 AX 查询 focusedWindow/windowHandle —— 焦点窗口位于副屏 space 时
    /// AX kAXFocusedWindowAttribute 被 WindowServer 阻塞 1-2s（toggle-00005438 gap2
    /// 1058ms 同源，一次 toggle 原先在此重复 3 次 AX 查询）。windowID==nil 时
    /// （测试 / 非 toggle 入口）保留 AX 查询以维持既有行为。
    /// isWindowOnMainScreen 与 store.load 均按 windowID 走 CGWindowList / SQLite，非阻塞。
    func shouldRestoreCurrentWindow(windowID: UInt32?, store: ToggleRecordStore) -> Bool {
        // P-INST-76: shouldRestore 决策总耗时（toggle 决策核心，plan P0.2 gap2 优化点；windowID 传入走 CGWindowList+SQLite 非阻塞，windowID==nil 走 AX focusedWindow/windowHandle 可阻塞；子调用 hasAccessibilityPermission P-INST-64 / isWindowOnMainScreen P-INST-61 / store.load P-INST-18 / store.clear P-INST-67 已埋，此为顶层聚合归因）。
        let srStart = Date()
        defer {
            log("[WindowManager] shouldRestoreCurrentWindow finished", level: .debug, fields: [
                "hadWindowID": String(windowID != nil),
                "durationMs": String(elapsedMilliseconds(since: srStart))
            ])
        }
        if !hasAccessibilityPermission() {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: no AX permission, cannot determine",
                level: .debug
            )
            return false
        }

        let currentWindowID: UInt32
        if let resolved = windowID {
            // toggle 入口已用 CGWindowList 解析的 windowID，直接复用，跳过 AX 查询。
            currentWindowID = resolved
        } else {
            guard let frontApp = NSWorkspace.shared.frontmostApplication,
                  let focusedWindow = focusedWindow(for: frontApp.processIdentifier),
                  let resolvedID = windowHandle(for: focusedWindow) else {
                log(
                    "[WindowManager] shouldRestoreCurrentWindow: cannot identify focused window",
                    level: .debug,
                    fields: [
                        "hasFrontApp": String(NSWorkspace.shared.frontmostApplication != nil)
                    ]
                )
                return false
            }
            currentWindowID = resolvedID
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
