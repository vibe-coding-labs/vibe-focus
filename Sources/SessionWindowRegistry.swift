import Foundation

@MainActor
final class SessionWindowRegistry: ObservableObject {
    static let shared = SessionWindowRegistry()

    @Published private(set) var bindings: [String: SessionWindowBinding] = [:]
    @Published private(set) var lastEventDescription: String = "尚未收到 Claude Hook 事件"

    var activeBindingCount: Int {
        bindings.values.filter { !$0.isCompleted }.count
    }

    var completedBindingCount: Int {
        bindings.values.filter(\.isCompleted).count
    }

    private let storageKey = "claudeSessionWindowBindings.v1"
    private let completedRetention: TimeInterval = 30 * 60
    private let activeRetention: TimeInterval = 12 * 60 * 60

    private init() {
        bindings = loadBindings()
        log("SessionWindowRegistry.init entry", level: .debug, fields: ["loadedBindingCount": String(bindings.count)])
        pruneExpiredBindings(shouldPersist: false)
        log("SessionWindowRegistry.init exit", level: .debug, fields: ["activeCount": String(activeBindingCount), "completedCount": String(completedBindingCount)])
    }

    func bind(sessionID: String, windowIdentity: WindowIdentity) {
        log("SessionWindowRegistry.bind entry", level: .debug, fields: ["sessionID": sessionID, "appName": windowIdentity.appName ?? "nil", "title": windowIdentity.title ?? "nil"])
        let now = Date()
        let normalizedSession = normalizeSessionID(sessionID)
        guard !normalizedSession.isEmpty else {
            log("SessionWindowRegistry.bind empty sessionID after normalization", level: .debug)
            return
        }

        if var existing = bindings[normalizedSession] {
            log("SessionWindowRegistry.bind updating existing binding", level: .debug, fields: ["normalizedSession": normalizedSession])
            existing.windowIdentity = windowIdentity
            existing.lastSeenAt = now
            existing.isCompleted = false
            existing.completedAt = nil
            bindings[normalizedSession] = existing
        } else {
            log("SessionWindowRegistry.bind creating new binding", level: .debug, fields: ["normalizedSession": normalizedSession])
            bindings[normalizedSession] = SessionWindowBinding(
                sessionID: normalizedSession,
                windowIdentity: windowIdentity,
                createdAt: now,
                lastSeenAt: now,
                isCompleted: false,
                completedAt: nil
            )
        }
        lastEventDescription = "SessionStart 绑定窗口：\(windowIdentity.appName ?? "Unknown") / \(windowIdentity.title ?? "Untitled")"
        pruneExpiredBindings(shouldPersist: false)
        persistBindings()
        log("SessionWindowRegistry.bind exit", level: .debug, fields: ["normalizedSession": normalizedSession, "totalBindings": String(bindings.count)])
    }

    func binding(for sessionID: String) -> SessionWindowBinding? {
        log("SessionWindowRegistry.binding lookup entry", level: .debug, fields: ["sessionID": sessionID])
        let normalizedSession = normalizeSessionID(sessionID)
        guard !normalizedSession.isEmpty else {
            log("SessionWindowRegistry.binding empty sessionID", level: .debug)
            return nil
        }
        let result = bindings[normalizedSession]
        log("SessionWindowRegistry.binding lookup exit", level: .debug, fields: ["normalizedSession": normalizedSession, "found": String(result != nil)])
        return result
    }

    func markCompleted(sessionID: String) {
        log("SessionWindowRegistry.markCompleted entry", level: .debug, fields: ["sessionID": sessionID])
        let normalizedSession = normalizeSessionID(sessionID)
        guard !normalizedSession.isEmpty, var binding = bindings[normalizedSession] else {
            log("SessionWindowRegistry.markCompleted session not found or empty", level: .debug, fields: ["sessionID": sessionID])
            return
        }
        binding.isCompleted = true
        binding.completedAt = Date()
        binding.lastSeenAt = Date()
        bindings[normalizedSession] = binding
        lastEventDescription = "SessionEnd 已完成：\(binding.windowIdentity.appName ?? "Unknown") / \(binding.windowIdentity.title ?? "Untitled")"
        persistBindings()
        log("SessionWindowRegistry.markCompleted exit", level: .debug, fields: ["normalizedSession": normalizedSession, "appName": binding.windowIdentity.appName ?? "nil"])
    }

    /// 将已完成的绑定重新激活，使下一个 Stop 事件能再次触发窗口移动
    func reactivate(sessionID: String) {
        log("SessionWindowRegistry.reactivate entry", level: .debug, fields: ["sessionID": sessionID])
        let normalizedSession = normalizeSessionID(sessionID)
        guard !normalizedSession.isEmpty, var binding = bindings[normalizedSession] else {
            log("SessionWindowRegistry.reactivate session not found or empty", level: .debug, fields: ["sessionID": sessionID])
            return
        }
        binding.isCompleted = false
        binding.completedAt = nil
        binding.lastSeenAt = Date()
        bindings[normalizedSession] = binding
        persistBindings()
        log("SessionWindowRegistry.reactivate exit", level: .debug, fields: ["normalizedSession": normalizedSession])
    }

    func touch(sessionID: String, message: String? = nil) {
        log("SessionWindowRegistry.touch entry", level: .debug, fields: ["sessionID": sessionID, "hasMessage": String(message != nil)])
        let normalizedSession = normalizeSessionID(sessionID)
        guard !normalizedSession.isEmpty else {
            log("SessionWindowRegistry.touch empty sessionID", level: .debug)
            return
        }
        if var binding = bindings[normalizedSession] {
            log("SessionWindowRegistry.touch updating lastSeenAt", level: .debug, fields: ["normalizedSession": normalizedSession])
            binding.lastSeenAt = Date()
            bindings[normalizedSession] = binding
            persistBindings()
        } else {
            log("SessionWindowRegistry.touch session not found", level: .debug, fields: ["normalizedSession": normalizedSession])
        }
        if let message, !message.isEmpty {
            lastEventDescription = message
        }
    }

    func setLastEventDescription(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        lastEventDescription = message
    }

    // MARK: - UI Support

    /// 活跃（未完成）的绑定列表，按创建时间倒序
    var activeBindingsForUI: [SessionWindowBinding] {
        bindings.values
            .filter { !$0.isCompleted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 最近完成的绑定（30 分钟内），按完成时间倒序
    var recentCompletedBindings: [SessionWindowBinding] {
        let now = Date()
        return bindings.values
            .filter { binding in
                guard binding.isCompleted else { return false }
                let deadline = (binding.completedAt ?? binding.lastSeenAt).addingTimeInterval(30 * 60)
                return deadline > now
            }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// 清除所有绑定（供 UI 调试用）
    func clearAllBindings() {
        log("SessionWindowRegistry.clearAllBindings entry", level: .debug, fields: ["count": String(bindings.count)])
        bindings.removeAll()
        lastEventDescription = "所有绑定已清除"
        persistBindings()
        log("SessionWindowRegistry.clearAllBindings exit", level: .debug)
    }

    private func normalizeSessionID(_ sessionID: String) -> String {
        sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pruneExpiredBindings(shouldPersist: Bool = true) {
        log("SessionWindowRegistry.pruneExpiredBindings entry", level: .debug, fields: ["bindingCount": String(bindings.count)])
        let now = Date()
        let previousCount = bindings.count
        bindings = bindings.filter { _, binding in
            if binding.isCompleted {
                let deadline = (binding.completedAt ?? binding.lastSeenAt).addingTimeInterval(completedRetention)
                return deadline > now
            }
            let deadline = binding.lastSeenAt.addingTimeInterval(activeRetention)
            return deadline > now
        }
        let removedCount = previousCount - bindings.count
        if removedCount > 0 {
            log("SessionWindowRegistry.pruneExpiredBindings pruned", level: .debug, fields: ["removedCount": String(removedCount), "remaining": String(bindings.count)])
        }
        if shouldPersist && bindings.count != previousCount {
            persistBindings()
        }
    }

    private func persistBindings() {
        log("SessionWindowRegistry.persistBindings entry", level: .debug, fields: ["bindingCount": String(bindings.count)])
        guard let data = try? JSONEncoder().encode(bindings) else {
            log("SessionWindowRegistry failed to encode bindings")
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
        log("SessionWindowRegistry.persistBindings exit", level: .debug, fields: ["dataSize": String(data.count)])
    }

    private func loadBindings() -> [String: SessionWindowBinding] {
        log("SessionWindowRegistry.loadBindings entry", level: .debug, fields: ["storageKey": storageKey])
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: SessionWindowBinding].self, from: data) else {
            log("SessionWindowRegistry.loadBindings no saved data or decode failed", level: .debug)
            return [:]
        }
        log("SessionWindowRegistry.loadBindings exit", level: .debug, fields: ["loadedCount": String(decoded.count)])
        return decoded
    }
}
