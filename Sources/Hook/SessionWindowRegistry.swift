import Foundation
import Cocoa

// 查找与 UI 支持已移至 SessionWindowRegistry+Lookup.swift
// 状态更新与批量操作已移至 SessionWindowRegistry+State.swift
// 绑定验证已移至 BindingVerifier.swift

@MainActor
final class SessionWindowRegistry: ObservableObject {
    static let shared = SessionWindowRegistry()

    @Published var lastEventDescription: String = "尚未收到 Claude Hook 事件"

    /// 内存缓存：key = windowID (CGWindowNumber)，value = WindowState
    var windowStates: [UInt32: WindowState] = [:]

    /// 次要映射：当同一窗口有多个活跃会话时（如远程 SSH 共享同一 iTerm 窗口），
    /// 记录 sessionID → windowID 的关系，让 UserPromptSubmit 能找到正确的窗口。
    var sessionAliasWindowID: [String: UInt32] = [:]

    var activeBindingCount: Int {
        windowStates.values.filter { !$0.isCompleted }.count
    }

    var completedBindingCount: Int {
        windowStates.values.filter(\.isCompleted).count
    }

    let completedRetention: TimeInterval = 4 * 60 * 60
    let activeRetention: TimeInterval = 24 * 60 * 60

    private init() {
        let loaded = WindowStateStore.shared.loadAllWindowStates()
        var prunedCount = 0
        for state in loaded {
            if TerminalRegistry.isTerminalPID(state.pid) {
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

    func bind(sessionID: String, windowIdentity: WindowIdentity, terminalTTY: String? = nil, terminalSessionID: String? = nil, itermSessionID: String? = nil, cwd: String? = nil, model: String? = nil, bindingType: WindowState.BindingType = .local) {
        let now = Date()
        let wid = windowIdentity.windowID

        log("[SessionWindowRegistry] bind called", fields: [
            "sessionID": sessionID,
            "windowID": String(wid),
            "pid": String(windowIdentity.pid),
            "app": windowIdentity.appName ?? "unknown",
            "bindingType": bindingType.rawValue,
            "tty": terminalTTY ?? "nil",
            "itermSessionID": itermSessionID ?? "nil",
            "cwd": cwd ?? "nil"
        ])

        guard TerminalRegistry.isTerminalPID(windowIdentity.pid) else {
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
            // Don't overwrite an active binding from a different session
            if let existingSID = existing.sessionID, existingSID != sessionID, !existing.isCompleted {
                log("[SessionWindowRegistry] bind alias: windowID \(wid) already has active binding for session \(existingSID.prefix(8)), recording alias for session \(sessionID.prefix(8))", level: .info, fields: [
                    "windowID": String(wid),
                    "existingSessionID": existingSID,
                    "newSessionID": sessionID,
                    "existingBindingType": existing.bindingType.rawValue,
                    "newBindingType": bindingType.rawValue
                ])
                sessionAliasWindowID[sessionID] = wid
                lastEventDescription = "SessionStart 别名绑定：\(windowIdentity.appName ?? "Unknown") / \(sessionID.prefix(8))"
                return
            }
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
            existing.bindingType = bindingType
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
                bindingType: bindingType,
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
        log("[SessionWindowRegistry] bind completed", fields: [
            "sessionID": sessionID,
            "windowID": String(wid),
            "bindingType": bindingType.rawValue,
            "activeBindings": String(activeBindingCount),
            "totalBindings": String(windowStates.count)
        ])
    }

    // MARK: - Private

    func pruneExpiredBindings(shouldPersist: Bool = true) {
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

    func persistToDB(windowID: UInt32) {
        guard let state = windowStates[windowID] else { return }
        WindowStateStore.shared.saveWindowState(state)
    }
}
