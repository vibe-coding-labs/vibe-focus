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
        for state in loaded {
            windowStates[state.windowID] = state
        }
        log("SessionWindowRegistry.init loaded \(loaded.count) window states from SQLite")
        pruneExpiredBindings(shouldPersist: false)
    }

    // MARK: - Bind

    func bind(sessionID: String, windowIdentity: WindowIdentity, terminalTTY: String? = nil, terminalSessionID: String? = nil, itermSessionID: String? = nil, cwd: String? = nil, model: String? = nil) {
        let now = Date()
        let wid = windowIdentity.windowID

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
    func binding(for sessionID: String) -> WindowState? {
        if let state = windowStates.values.first(where: { $0.sessionID == sessionID }) {
            return state
        }
        if let state = WindowStateStore.shared.findWindowStateBySession(sessionID: sessionID) {
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
            if !pidExists { return false }
        }

        let options: CGWindowListOption = [.optionAll]
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            if let matchedWindow = windowList.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID }) {
                let actualPID = matchedWindow[kCGWindowOwnerPID as String] as? Int32
                return actualPID == expectedPID
            } else {
                return false
            }
        }
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

    // MARK: - Toggle State

    /// 按 windowID 更新 toggle state（由 WindowManager 调用）
    func updateToggleState(windowID: UInt32, toggleUpdater: (inout WindowState) -> Void) {
        if var state = windowStates[windowID] {
            toggleUpdater(&state)
            state.updatedAt = Date()
            windowStates[windowID] = state
            persistToDB(windowID: windowID)
        } else {
            var state = WindowState(
                windowID: windowID,
                pid: 0,
                isCompleted: false,
                createdAt: Date(),
                updatedAt: Date()
            )
            toggleUpdater(&state)
            windowStates[windowID] = state
            persistToDB(windowID: windowID)
        }
    }

    /// 清除指定窗口的 toggle state
    func clearToggleState(windowID: UInt32) {
        if var state = windowStates[windowID] {
            state.origX = nil; state.origY = nil; state.origW = nil; state.origH = nil
            state.targetX = nil; state.targetY = nil; state.targetW = nil; state.targetH = nil
            state.sourceSpace = nil; state.sourceDisplay = nil; state.sourceYabaiDisp = nil
            state.sourceDispSpace = nil; state.targetDisplay = nil
            state.toggleReason = nil; state.toggledAt = nil
            state.updatedAt = Date()
            windowStates[windowID] = state
            persistToDB(windowID: windowID)
        }
        WindowStateStore.shared.clearToggleState(windowID: windowID)
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

    private func persistToDB(windowID: UInt32) {
        guard let state = windowStates[windowID] else { return }
        WindowStateStore.shared.saveWindowState(state)
    }
}
