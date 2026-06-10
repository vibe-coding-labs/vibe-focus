// SessionWindowRegistry+Lookup.swift
// VibeFocus — Session 窗口绑定查找与 UI 支持
// 从 SessionWindowRegistry.swift 中提取

import Foundation

@MainActor
extension SessionWindowRegistry {

    // MARK: - Lookup

    /// 按 sessionID 查找窗口状态（扫描，低频操作）
    /// 优先返回 PID 有效的绑定，避免返回损坏数据
    func binding(for sessionID: String) -> WindowState? {
        // 1. Direct lookup: binding has this sessionID
        let candidates = windowStates.values.filter { $0.sessionID == sessionID }
        if let valid = candidates.first(where: { TerminalRegistry.isTerminalPID($0.pid) }) {
            return valid
        }
        if let first = candidates.first {
            return first
        }

        // 2. Alias lookup: session shares a window with another session
        if let aliasWindowID = sessionAliasWindowID[sessionID],
           let state = windowStates[aliasWindowID] {
            log("[SessionWindowRegistry] binding(for:) resolved via alias", fields: [
                "sessionID": sessionID,
                "windowID": String(aliasWindowID),
                "boundSessionID": String(state.sessionID?.prefix(8) ?? "nil")
            ])
            return state
        }

        // 3. DB fallback
        if let state = WindowStateStore.shared.findWindowStateBySession(sessionID: sessionID) {
            if !TerminalRegistry.isTerminalPID(state.pid) {
                log("[SessionWindowRegistry] binding(for:) loaded corrupt binding from DB, cleaning up", level: .warn, fields: [
                    "windowID": String(state.windowID),
                    "pid": String(state.pid),
                    "sessionID": sessionID
                ])
                WindowStateStore.shared.deleteWindowState(windowID: state.windowID)
                return nil
            }
            windowStates[state.windowID] = state
            return state
        }
        return nil
    }

    /// 按 windowID 查找窗口状态（O(1)，主查找路径）
    func findState(windowID: UInt32) -> WindowState? {
        if let state = windowStates[windowID] {
            return state
        }
        if let state = WindowStateStore.shared.findWindowState(windowID: windowID) {
            windowStates[state.windowID] = state
            return state
        }
        return nil
    }

    /// 根据 windowID 查找绑定信息（返回轻量结构，不暴露内部 WindowState）
    func findBinding(forWindowID windowID: UInt32) -> (tty: String?, termSessionID: String?, itermSessionID: String?, sessionID: String?, cwd: String?, model: String?)? {
        guard let state = windowStates[windowID] else { return nil }
        return (
            tty: state.tty,
            termSessionID: state.termSessionID,
            itermSessionID: state.itermSessionID,
            sessionID: state.sessionID,
            cwd: state.cwd,
            model: state.model
        )
    }

    // MARK: - UI Support

    var activeBindingsForUI: [WindowState] {
        windowStates.values
            .filter { !$0.isCompleted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var recentCompletedBindings: [WindowState] {
        let now = Date()
        return windowStates.values
            .filter { $0.isCompleted && $0.updatedAt.addingTimeInterval(30 * 60) > now }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
