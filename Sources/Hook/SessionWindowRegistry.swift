import Foundation
import Cocoa

@MainActor
final class SessionWindowRegistry: ObservableObject {
    static let shared = SessionWindowRegistry()

    @Published private(set) var lastEventDescription: String = "尚未收到 Claude Hook 事件"

    /// 内存缓存：key = windowID (CGWindowNumber)，value = WindowState
    private(set) var windowStates: [UInt32: WindowState] = [:]

    var activeBindingCount: Int {
        windowStates.values.filter { !$0.isCompleted }.count
    }

    var completedBindingCount: Int {
        windowStates.values.filter(\.isCompleted).count
    }

    private let completedRetention: TimeInterval = 4 * 60 * 60
    private let activeRetention: TimeInterval = 24 * 60 * 60

    private init() {
        let loaded = WindowStateStore.shared.loadAllWindowStates()
        var prunedCount = 0
        for state in loaded {
            if TerminalAppRegistry.isTerminalPID(state.pid) {
                windowStates[state.windowID] = state
            } else {
                WindowStateStore.shared.deleteWindowState(windowID: state.windowID)
                prunedCount += 1
                log("[SessionWindowRegistry] init pruned corrupt binding: wid=\(state.windowID) pid=\(state.pid) app=\(state.appName ?? "nil") sid=\(state.sessionID?.prefix(8) ?? "nil")")
            }
        }
        log("SessionWindowRegistry.init loaded \(loaded.count - prunedCount) valid window states, pruned \(prunedCount) corrupt bindings")
        pruneExpiredBindings(shouldPersist: false)
    }

    // MARK: - Bind

    func bind(sessionID: String, windowIdentity: WindowIdentity, terminalTTY: String? = nil, terminalSessionID: String? = nil, itermSessionID: String? = nil, cwd: String? = nil, model: String? = nil) {
        let now = Date()
        let wid = windowIdentity.windowID

        guard TerminalAppRegistry.isTerminalPID(windowIdentity.pid) else {
            log("[SessionWindowRegistry] bind rejected: PID is not a terminal app", level: .warn, fields: [
                "windowID": String(wid),
                "pid": String(windowIdentity.pid),
                "sessionID": sessionID,
                "appName": windowIdentity.appName ?? "nil"
            ])
            return
        }

        var resolvedWindowNumber = windowIdentity.windowNumber
        if resolvedWindowNumber == nil, let axWindow = WindowManager.shared.resolveWindow(identity: windowIdentity) {
            resolvedWindowNumber = WindowManager.shared.windowNumber(for: axWindow)
        }

        if var existing = windowStates[wid] {
            existing.pid = windowIdentity.pid
            existing.tty = terminalTTY
            existing.axWindowNumber = resolvedWindowNumber
            existing.appName = windowIdentity.appName
            existing.bundleIdentifier = windowIdentity.bundleIdentifier
            existing.title = windowIdentity.title
            existing.sessionID = sessionID
            existing.isCompleted = false
            existing.completedAt = nil
            existing.updatedAt = now
            existing.termSessionID = terminalSessionID
            existing.itermSessionID = itermSessionID
            existing.cwd = cwd
            existing.model = model
            windowStates[wid] = existing
        } else {
            var state = WindowState(
                windowID: wid,
                pid: windowIdentity.pid,
                tty: terminalTTY,
                axWindowNumber: resolvedWindowNumber,
                appName: windowIdentity.appName,
                bundleIdentifier: windowIdentity.bundleIdentifier,
                title: windowIdentity.title,
                termSessionID: terminalSessionID,
                itermSessionID: itermSessionID,
                sessionID: sessionID,
                isCompleted: false,
                createdAt: now,
                updatedAt: now
            )
            state.cwd = cwd
            state.model = model
            windowStates[wid] = state
        }

        lastEventDescription = "SessionStart 绑定窗口：\(windowIdentity.appName ?? "Unknown") / \(windowIdentity.title ?? "Untitled")"
        pruneExpiredBindings(shouldPersist: false)
        persistToDB(windowID: wid)
    }

    // MARK: - Lookup

    /// 按 sessionID 查找窗口状态（扫描，低频操作）
    /// 优先返回 PID 有效的绑定，避免返回损坏数据
    func binding(for sessionID: String) -> WindowState? {
        let candidates = windowStates.values.filter { $0.sessionID == sessionID }
        if let valid = candidates.first(where: { TerminalAppRegistry.isTerminalPID($0.pid) }) {
            return valid
        }
        if let first = candidates.first {
            return first
        }
        if let state = WindowStateStore.shared.findWindowStateBySession(sessionID: sessionID) {
            if !TerminalAppRegistry.isTerminalPID(state.pid) {
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

    // MARK: - Verify

    func verifyBinding(_ state: WindowState) -> Bool {
        let expectedPID = state.pid
        let windowID = state.windowID

        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: state.bundleIdentifier ?? "")
        let pidMatches = runningApps.contains { $0.processIdentifier == expectedPID }
        if !pidMatches {
            let pidExists = kill(expectedPID, 0) == 0
            if !pidExists {
                log("[SessionWindowRegistry] verifyBinding failed: PID \(expectedPID) no longer exists", level: .warn, fields: [
                    "windowID": String(windowID),
                    "bundleIdentifier": state.bundleIdentifier ?? "nil"
                ])
                return false
            }
        }

        let options: CGWindowListOption = [.optionAll]
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            if let matchedWindow = windowList.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID }) {
                let actualPID = matchedWindow[kCGWindowOwnerPID as String] as? Int32
                if actualPID != expectedPID {
                    log("[SessionWindowRegistry] verifyBinding failed: window owner PID mismatch", level: .warn, fields: [
                        "windowID": String(windowID),
                        "expectedPID": String(expectedPID),
                        "actualPID": String(describing: actualPID)
                    ])
                }
                return actualPID == expectedPID
            } else {
                log("[SessionWindowRegistry] verifyBinding failed: windowID \(windowID) not found in CGWindowList", level: .warn, fields: [
                    "windowID": String(windowID),
                    "expectedPID": String(expectedPID)
                ])
                return false
            }
        }
        log("[SessionWindowRegistry] verifyBinding failed: CGWindowListCopyWindowInfo returned nil", level: .warn, fields: [
            "windowID": String(windowID)
        ])
        return false
    }

    // MARK: - State Updates

    func markCompleted(sessionID: String) {
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
        lastEventDescription = "所有绑定已清除"
        WindowStateStore.shared.deleteAllWindowsStates()
    }

    func purgeClosedWindows() {
        let options: CGWindowListOption = [.optionAll]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        var activeWindowIDs: Set<UInt32> = []
        for info in windowList {
            if let wid = info[kCGWindowNumber as String] as? UInt32 {
                activeWindowIDs.insert(wid)
            }
        }

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

    // MARK: - Private

    private func pruneExpiredBindings(shouldPersist: Bool = true) {
        let removed = WindowStateStore.shared.pruneExpiredWindowStates(
            activeRetention: activeRetention,
            completedRetention: completedRetention
        )
        if removed > 0 {
            let now = Date()
            windowStates = windowStates.filter { _, state in
                let deadline = state.updatedAt.addingTimeInterval(
                    state.isCompleted ? completedRetention : activeRetention
                )
                return deadline > now
            }
        }
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

    private func persistToDB(windowID: UInt32) {
        guard let state = windowStates[windowID] else { return }
        WindowStateStore.shared.saveWindowState(state)
    }
}
