// SessionWindowRegistry+State.swift
// VibeFocus — Session 窗口状态更新与批量操作
// 从 SessionWindowRegistry.swift 中提取

import Foundation

@MainActor
extension SessionWindowRegistry {

    // MARK: - State Updates

    func markCompleted(sessionID: String) {
        sessionAliasWindowID.removeValue(forKey: sessionID)
        guard let state = binding(for: sessionID) else { return }
        guard var updated = windowStates[state.windowID] else { return }
        updated.isCompleted = true
        updated.completedAt = Date()
        updated.updatedAt = Date()
        windowStates[state.windowID] = updated
        lastEventDescription = "SessionEnd 已完成：\(updated.appName ?? "Unknown")"
        persistToDB(windowID: state.windowID)
    }

    func reactivate(sessionID: String) {
        guard let state = binding(for: sessionID) else { return }
        guard var updated = windowStates[state.windowID] else { return }
        updated.isCompleted = false
        updated.completedAt = nil
        updated.updatedAt = Date()
        windowStates[state.windowID] = updated
        persistToDB(windowID: state.windowID)
    }

    func touch(sessionID: String, message: String? = nil) {
        guard let state = binding(for: sessionID) else { return }
        guard var updated = windowStates[state.windowID] else { return }
        updated.updatedAt = Date()
        windowStates[state.windowID] = updated
        persistToDB(windowID: state.windowID)
        if let message, !message.isEmpty {
            lastEventDescription = message
        }
    }

    func setLastEventDescription(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastEventDescription = message
    }

    /// 将旧 windowID 的绑定重映射到新 windowID（CGWindowNumber 变化时调用）
    func remapWindowID(oldWindowID: UInt32, newWindowID: UInt32) {
        guard oldWindowID != newWindowID else { return }
        guard var state = windowStates[oldWindowID] else {
            // 旧 windowID 不在内存缓存中 — 尝试从 DB 加载
            if let dbState = WindowStateStore.shared.findWindowState(windowID: oldWindowID) {
                var remapped = dbState
                remapped.windowID = newWindowID
                windowStates[newWindowID] = remapped
                persistToDB(windowID: newWindowID)
                WindowStateStore.shared.deleteWindowState(windowID: oldWindowID)
                windowStates.removeValue(forKey: oldWindowID)
                log("[SessionWindowRegistry] remapWindowID: DB remap", fields: [
                    "oldWindowID": String(oldWindowID),
                    "newWindowID": String(newWindowID)
                ])
            }
            return
        }
        state.windowID = newWindowID
        windowStates[newWindowID] = state
        windowStates.removeValue(forKey: oldWindowID)
        WindowStateStore.shared.deleteWindowState(windowID: oldWindowID)
        persistToDB(windowID: newWindowID)
        log("[SessionWindowRegistry] remapWindowID: memory+DB remap", fields: [
            "oldWindowID": String(oldWindowID),
            "newWindowID": String(newWindowID)
        ])
    }

    // MARK: - Bulk Operations

    func clearAllBindings() {
        windowStates.removeAll()
        sessionAliasWindowID.removeAll()
        lastEventDescription = "所有绑定已清除"
        WindowStateStore.shared.deleteAllWindowsStates()
    }

    func purgeClosedWindows() {
        let windows = cgWindowListAll()
        let activeWindowIDs = Set(windows.map { $0.windowID })

        let keysToRemove = windowStates.filter { _, state in
            guard !state.isCompleted else { return false }
            return !activeWindowIDs.contains(state.windowID)
        }.map(\.key)

        for key in keysToRemove {
            if let state = windowStates[key] {
                log("[SessionWindowRegistry] purging closed window: wid=\(state.windowID) pid=\(state.pid) app=\(state.appName ?? "unknown")")
                WindowStateStore.shared.deleteWindowState(windowID: state.windowID)
            }
            windowStates.removeValue(forKey: key)
        }
    }
}
