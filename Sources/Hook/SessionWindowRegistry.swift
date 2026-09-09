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

    private var activeBindingCount: Int {
        windowStates.values.filter { !$0.isCompleted }.count
    }

    private var completedBindingCount: Int {
        windowStates.values.filter(\.isCompleted).count
    }

    private let completedRetention: TimeInterval = 4 * 60 * 60
    private let activeRetention: TimeInterval = 24 * 60 * 60

    /// 持久层（依赖注入点，B32）：生产走 `.shared`（env 可重定向 DB 路径），
    /// 测试注入临时 `WindowStateStore(dbPath:)` 实现无环境门控的直测。
    let store: WindowStateStore

    init(store: WindowStateStore = .shared) {
        self.store = store
        let loaded = store.loadAllWindowStates()
        var prunedCount = 0
        for state in loaded {
            if TerminalRegistry.isTerminalPID(state.pid) {
                windowStates[state.windowID] = state
            } else {
                store.deleteWindowState(windowID: state.windowID)
                prunedCount += 1
                log("[SessionWindowRegistry] init pruned corrupt binding: wid=\(state.windowID) pid=\(state.pid) app=\(state.appName ?? "nil") sid=\(state.sessionID?.prefix(8) ?? "nil")")
            }
        }
        log("SessionWindowRegistry.init loaded \(loaded.count - prunedCount) valid window states, pruned \(prunedCount) corrupt bindings")
        pruneExpiredBindings(shouldPersist: false)
    }

    // MARK: - Bind

    func bind(sessionID: String, windowIdentity: WindowIdentity, terminalTTY: String? = nil, terminalSessionID: String? = nil, itermSessionID: String? = nil, cwd: String? = nil, model: String? = nil, bindingType: WindowState.BindingType = .local) {
        // P-INST-149: session 绑定编排耗时（TerminalRegistry.isTerminalPID 查 + WindowManager.resolveWindow AX 解析 + windowNumber AX 读取 + pruneExpiredBindings P-INST-150 + persistToDB P-INST-151 SQLite 写；hook SessionStart 热路径，AX 解析在副屏 space 可阻塞）。
        #if PERF_INSTRUMENT
        let bindStart = Date()
        defer {
            log("[SessionWindowRegistry] bind finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: bindStart))
            ])
        }
        #endif
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

        switch Self.makeBoundState(
            existing: windowStates[wid], sessionID: sessionID, identity: windowIdentity,
            resolvedWindowNumber: resolvedWindowNumber, terminalTTY: terminalTTY,
            terminalSessionID: terminalSessionID, itermSessionID: itermSessionID,
            cwd: cwd, model: model, bindingType: bindingType, now: now
        ) {
        case .alias(let existingSID):
            log("[SessionWindowRegistry] bind alias: windowID \(wid) already has active binding for session \(existingSID.prefix(8)), recording alias for session \(sessionID.prefix(8))", level: .info, fields: [
                "windowID": String(wid),
                "existingSessionID": existingSID,
                "newSessionID": sessionID,
                "existingBindingType": windowStates[wid]?.bindingType.rawValue ?? "?",
                "newBindingType": bindingType.rawValue
            ])
            sessionAliasWindowID[sessionID] = wid
            lastEventDescription = "SessionStart 别名绑定：\(windowIdentity.appName ?? "Unknown") / \(sessionID.prefix(8))"
            return
        case .merged(let state), .created(let state):
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

    // MARK: - Pure Decision

    /// bind 的身份合并纯决策（B98 测试缝提纯，原内联在 bind）：
    /// - `.alias(existingSID)`：窗口已有**其他 session 的活跃绑定**（未 completed）——
    ///   不覆盖，调用方记录 session 别名后结束；
    /// - `.merged(state)`：同 session 重绑或已完成绑定复用——刷新身份/上下文字段并复活；
    /// - `.created(state)`：无既有记录——新建绑定。
    static func makeBoundState(
        existing: WindowState?,
        sessionID: String,
        identity: WindowIdentity,
        resolvedWindowNumber: Int?,
        terminalTTY: String?,
        terminalSessionID: String?,
        itermSessionID: String?,
        cwd: String?,
        model: String?,
        bindingType: WindowState.BindingType,
        now: Date
    ) -> BindOutcome {
        let wid = identity.windowID
        if var state = existing {
            // Don't overwrite an active binding from a different session
            if let existingSID = state.sessionID, existingSID != sessionID, !state.isCompleted {
                return .alias(existingSessionID: existingSID)
            }
            state.pid = identity.pid
            state.tty = terminalTTY
            state.axWindowNumber = resolvedWindowNumber
            state.appName = identity.appName
            state.bundleIdentifier = identity.bundleIdentifier
            state.title = identity.title
            state.sessionID = sessionID
            state.isCompleted = false
            state.completedAt = nil
            state.updatedAt = now
            state.termSessionID = terminalSessionID
            state.itermSessionID = itermSessionID
            state.cwd = cwd
            state.model = model
            state.bindingType = bindingType
            return .merged(state)
        }
        var state = WindowState(
            windowID: wid,
            pid: identity.pid,
            tty: terminalTTY,
            axWindowNumber: resolvedWindowNumber,
            appName: identity.appName,
            bundleIdentifier: identity.bundleIdentifier,
            title: identity.title,
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
        return .created(state)
    }

    /// makeBoundState 的三态结局。
    enum BindOutcome: Equatable {
        /// 窗口已被其他活跃 session 占用（携带既有 sessionID），调用方记录别名
        case alias(existingSessionID: String)
        /// 既有记录刷新复用
        case merged(WindowState)
        /// 全新绑定
        case created(WindowState)
    }

    // MARK: - Private

    func pruneExpiredBindings(shouldPersist: Bool = true) {
        // P-INST-150: 过期绑定清理耗时（WindowStateStore.pruneExpiredWindowStates SQLite DELETE + 内存 windowStates filter；bind/init/clearAll 调用，定期回收过期绑定）。
        #if PERF_INSTRUMENT
        let pebStart = Date()
        defer {
            log("[SessionWindowRegistry] pruneExpiredBindings finished", level: .debug, fields: [
                "shouldPersist": String(shouldPersist),
                "durationMs": String(elapsedMilliseconds(since: pebStart))
            ])
        }
        #endif
        let removed = store.pruneExpiredWindowStates(
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
        // P-INST-151: 单窗口持久化耗时（windowStates 内存查 + WindowStateStore.saveWindowState SQLite INSERT...ON CONFLICT UPDATE P-INST-68；bind/markCompleted/reactivate/touch/remapWindowID 调用）。
        #if PERF_INSTRUMENT
        let pdbStart = Date()
        defer {
            log("[SessionWindowRegistry] persistToDB finished", level: .debug, fields: [
                "windowID": String(windowID),
                "durationMs": String(elapsedMilliseconds(since: pdbStart))
            ])
        }
        #endif
        guard let state = windowStates[windowID] else { return }
        store.saveWindowState(state)
    }
}
