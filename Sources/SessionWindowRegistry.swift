import Foundation
import Cocoa

@MainActor
final class SessionWindowRegistry: ObservableObject {
    static let shared = SessionWindowRegistry()

    @Published private(set) var lastEventDescription: String = "尚未收到 Claude Hook 事件"

    /// 内存缓存：key = "\(pid)_\(tty ?? "")"，value = WindowState
    private(set) var windowStates: [String: WindowState] = [:]

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
            let key = cacheKey(pid: state.pid, tty: state.tty)
            windowStates[key] = state
        }
        log("SessionWindowRegistry.init loaded \(loaded.count) window states from SQLite")
        pruneExpiredBindings(shouldPersist: false)
    }

    /// 绑定 session 到窗口 — 创建或更新 WindowState 行
    func bind(sessionID: String, windowIdentity: WindowIdentity, terminalTTY: String? = nil, terminalSessionID: String? = nil, itermSessionID: String? = nil, cwd: String? = nil, model: String? = nil) {
        let now = Date()
        let key = cacheKey(pid: windowIdentity.pid, tty: terminalTTY)

        // 如果 windowNumber 缺失，尝试通过 AX API 补充
        var resolvedWindowNumber = windowIdentity.windowNumber
        if resolvedWindowNumber == nil, let axWindow = WindowManager.shared.resolveWindow(identity: windowIdentity) {
            resolvedWindowNumber = WindowManager.shared.windowNumber(for: axWindow)
        }

        if var existing = windowStates[key] {
            existing.windowID = windowIdentity.windowID
            existing.axWindowNumber = resolvedWindowNumber
            existing.appName = windowIdentity.appName
            existing.bundleIdentifier = windowIdentity.bundleIdentifier
            existing.title = windowIdentity.title
            existing.sessionID = sessionID
            existing.isCompleted = false
            existing.completedAt = nil
            existing.updatedAt = now
            existing.tty = terminalTTY
            existing.termSessionID = terminalSessionID
            existing.itermSessionID = itermSessionID
            existing.cwd = cwd
            existing.model = model
            windowStates[key] = existing
        } else {
            var state = WindowState(
                pid: windowIdentity.pid,
                tty: terminalTTY,
                windowID: windowIdentity.windowID,
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
            windowStates[key] = state
        }

        lastEventDescription = "SessionStart 绑定窗口：\(windowIdentity.appName ?? "Unknown") / \(windowIdentity.title ?? "Untitled")"
        pruneExpiredBindings(shouldPersist: false)
        persistToDB(key: key)
    }

    /// 按 sessionID 查找窗口状态
    func binding(for sessionID: String) -> WindowState? {
        if let state = windowStates.values.first(where: { $0.sessionID == sessionID }) {
            return state
        }
        if let state = WindowStateStore.shared.findWindowStateBySession(sessionID: sessionID) {
            let key = cacheKey(pid: state.pid, tty: state.tty)
            windowStates[key] = state
            return state
        }
        return nil
    }

    /// 验证窗口状态是否仍然有效
    func verifyBinding(_ state: WindowState) -> Bool {
        guard let windowID = state.windowID else { return false }
        let expectedPID = state.pid

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

    /// 标记会话完成
    func markCompleted(sessionID: String) {
        guard let state = binding(for: sessionID) else { return }
        let key = cacheKey(pid: state.pid, tty: state.tty)
        guard var updated = windowStates[key] else { return }
        updated.isCompleted = true
        updated.completedAt = Date()
        updated.updatedAt = Date()
        windowStates[key] = updated
        lastEventDescription = "SessionEnd 已完成：\(updated.appName ?? "Unknown")"
        persistToDB(key: key)
    }

    /// 重新激活已完成的绑定
    func reactivate(sessionID: String) {
        guard let state = binding(for: sessionID) else { return }
        let key = cacheKey(pid: state.pid, tty: state.tty)
        guard var updated = windowStates[key] else { return }
        updated.isCompleted = false
        updated.completedAt = nil
        updated.updatedAt = Date()
        windowStates[key] = updated
        persistToDB(key: key)
    }

    /// 更新最后活跃时间
    func touch(sessionID: String, message: String? = nil) {
        guard let state = binding(for: sessionID) else { return }
        let key = cacheKey(pid: state.pid, tty: state.tty)
        guard var updated = windowStates[key] else { return }
        updated.updatedAt = Date()
        windowStates[key] = updated
        persistToDB(key: key)
        if let message, !message.isEmpty {
            lastEventDescription = message
        }
    }

    func setLastEventDescription(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastEventDescription = message
    }

    /// 更新指定窗口的 toggle state（由 WindowManager 调用）
    /// 当 tty 为 nil 时，自动查找该 PID 已有的行（优先选有 session 的行）
    func updateToggleState(pid: Int32, tty: String?, toggleUpdater: (inout WindowState) -> Void) {
        let key: String
        if let tty, !tty.isEmpty {
            key = cacheKey(pid: pid, tty: tty)
        } else {
            // tty 为空 — 查找该 PID 是否已有行（优先有 session_id 的行）
            let existingKey = windowStates.keys.first(where: { k in
                k.hasPrefix("\(pid)_") && windowStates[k]?.sessionID != nil
            }) ?? windowStates.keys.first(where: { k in
                k.hasPrefix("\(pid)_")
            })
            key = existingKey ?? cacheKey(pid: pid, tty: nil)
        }
        let existingState = windowStates[key]
        let hasExisting = existingState != nil
        let exSid = existingState?.sessionID?.prefix(8).description ?? "nil"
        log("[SessionWindowRegistry] updateToggleState pid=\(pid) tty=\(tty ?? "nil") key=\(key) foundExisting=\(hasExisting) exSid=\(exSid)")
        if var state = windowStates[key] {
            toggleUpdater(&state)
            state.updatedAt = Date()
            windowStates[key] = state
            let oX: String = if let v = state.origX { String(describing: v) } else { "nil" }
            let tX: String = if let v = state.targetX { String(describing: v) } else { "nil" }
            let sSp: String = if let v = state.sourceSpace { String(v) } else { "nil" }
            let tDsp: String = if let v = state.targetDisplay { String(v) } else { "nil" }
            log("[SessionWindowRegistry] updateToggleState UPDATED key=\(key) origX=\(oX) targetX=\(tX) srcSpace=\(sSp) tgtDisp=\(tDsp)")
            persistToDB(key: key)
        } else {
            var state = WindowState(
                pid: pid, tty: tty,
                isCompleted: false,
                createdAt: Date(), updatedAt: Date()
            )
            toggleUpdater(&state)
            windowStates[key] = state
            let oX: String = if let v = state.origX { String(describing: v) } else { "nil" }
            let tX: String = if let v = state.targetX { String(describing: v) } else { "nil" }
            let sSp: String = if let v = state.sourceSpace { String(v) } else { "nil" }
            let tDsp: String = if let v = state.targetDisplay { String(v) } else { "nil" }
            log("[SessionWindowRegistry] updateToggleState CREATED NEW key=\(key) origX=\(oX) targetX=\(tX) srcSpace=\(sSp) tgtDisp=\(tDsp)")
            persistToDB(key: key)
        }
    }

    /// 按 pid+tty 查找窗口状态（tty 为空时自动查找该 PID 的任意行）
    func findState(pid: Int32, tty: String?) -> WindowState? {
        if let tty, !tty.isEmpty {
            let key = cacheKey(pid: pid, tty: tty)
            if let state = windowStates[key] { return state }
            if let state = WindowStateStore.shared.findWindowState(pid: pid, tty: tty) {
                windowStates[key] = state
                return state
            }
        } else {
            // tty 为空 — 查找该 PID 的任意行（内存优先）
            if let state = windowStates.values.first(where: { $0.pid == pid }) {
                return state
            }
            // fallback: SQLite 中查找（无法按 PID 查全部，逐个试）
            return nil
        }
        return nil
    }

    /// 按 windowID 查找窗口状态
    func findStateByWindowID(_ windowID: UInt32) -> WindowState? {
        if let state = windowStates.values.first(where: { $0.windowID == windowID }) {
            return state
        }
        if let state = WindowStateStore.shared.findWindowStateByWindowID(windowID) {
            let key = cacheKey(pid: state.pid, tty: state.tty)
            windowStates[key] = state
            return state
        }
        return nil
    }

    /// 清除指定窗口的 toggle state
    func clearToggleState(pid: Int32, tty: String?) {
        let key = cacheKey(pid: pid, tty: tty)
        if var state = windowStates[key] {
            state.origX = nil; state.origY = nil; state.origW = nil; state.origH = nil
            state.targetX = nil; state.targetY = nil; state.targetW = nil; state.targetH = nil
            state.sourceSpace = nil; state.sourceDisplay = nil; state.sourceYabaiDisp = nil
            state.sourceDispSpace = nil; state.targetDisplay = nil
            state.toggleReason = nil; state.toggledAt = nil
            state.updatedAt = Date()
            windowStates[key] = state
            persistToDB(key: key)
        }
        WindowStateStore.shared.clearToggleState(pid: pid, tty: tty)
    }

    /// 清除所有绑定（调试用）
    func clearAllBindings() {
        windowStates.removeAll()
        lastEventDescription = "所有绑定已清除"
        WindowStateStore.shared.deleteAllWindowsStates()
    }

    /// 检查并清理已关闭窗口的记录
    /// 遍历所有 active 绑定，通过 CGWindowList 验证窗口是否仍存在
    func purgeClosedWindows() {
        let options: CGWindowListOption = [.optionAll]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        var pidWindows: [Int32: Set<UInt32>] = [:]
        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let wid = info[kCGWindowNumber as String] as? UInt32 else { continue }
            pidWindows[pid, default: []].insert(wid)
        }

        let keysToRemove = windowStates.filter { _, state in
            guard !state.isCompleted else { return false }
            guard let wid = state.windowID else { return false }
            let pidExists = pidWindows[state.pid] != nil
            if !pidExists { return true }
            return !(pidWindows[state.pid]?.contains(wid) ?? false)
        }.map(\.key)

        var purgedCount = 0
        for key in keysToRemove {
            if let state = windowStates[key] {
                log("[SessionWindowRegistry] purging closed window: pid=\(state.pid) tty=\(state.tty ?? "") app=\(state.appName ?? "unknown")")
                WindowStateStore.shared.deleteWindowState(pid: state.pid, tty: state.tty)
            }
            windowStates.removeValue(forKey: key)
            purgedCount += 1
        }

        if purgedCount > 0 {
            log("[SessionWindowRegistry] purgeClosedWindows removed \(purgedCount) stale records")
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

    private func cacheKey(pid: Int32, tty: String?) -> String {
        "\(pid)_\(tty ?? "")"
    }

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

    private func persistToDB(key: String) {
        guard let state = windowStates[key] else { return }
        WindowStateStore.shared.saveWindowState(state)
    }
}
