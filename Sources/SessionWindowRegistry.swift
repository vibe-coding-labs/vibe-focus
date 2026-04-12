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
        pruneExpiredBindings(shouldPersist: false)
    }

    func bind(sessionID: String, windowIdentity: WindowIdentity) {
        let now = Date()
        let normalizedSession = normalizeSessionID(sessionID)
        guard !normalizedSession.isEmpty else {
            return
        }

        if var existing = bindings[normalizedSession] {
            existing.windowIdentity = windowIdentity
            existing.lastSeenAt = now
            existing.isCompleted = false
            existing.completedAt = nil
            bindings[normalizedSession] = existing
        } else {
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
    }

    func binding(for sessionID: String) -> SessionWindowBinding? {
        let normalizedSession = normalizeSessionID(sessionID)
        guard !normalizedSession.isEmpty else {
            return nil
        }
        pruneExpiredBindings(shouldPersist: false)
        return bindings[normalizedSession]
    }

    func markCompleted(sessionID: String) {
        let normalizedSession = normalizeSessionID(sessionID)
        guard !normalizedSession.isEmpty, var binding = bindings[normalizedSession] else {
            return
        }
        binding.isCompleted = true
        binding.completedAt = Date()
        binding.lastSeenAt = Date()
        bindings[normalizedSession] = binding
        lastEventDescription = "SessionEnd 已完成：\(binding.windowIdentity.appName ?? "Unknown") / \(binding.windowIdentity.title ?? "Untitled")"
        persistBindings()
    }

    /// 将已完成的绑定重新激活，使下一个 Stop 事件能再次触发窗口移动
    func reactivate(sessionID: String) {
        let normalizedSession = normalizeSessionID(sessionID)
        guard !normalizedSession.isEmpty, var binding = bindings[normalizedSession] else {
            return
        }
        binding.isCompleted = false
        binding.completedAt = nil
        binding.lastSeenAt = Date()
        bindings[normalizedSession] = binding
        persistBindings()
    }

    func touch(sessionID: String, message: String? = nil) {
        let normalizedSession = normalizeSessionID(sessionID)
        guard !normalizedSession.isEmpty else {
            return
        }
        if var binding = bindings[normalizedSession] {
            binding.lastSeenAt = Date()
            bindings[normalizedSession] = binding
            persistBindings()
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
        bindings.removeAll()
        lastEventDescription = "所有绑定已清除"
        persistBindings()
    }

    private func normalizeSessionID(_ sessionID: String) -> String {
        sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pruneExpiredBindings(shouldPersist: Bool = true) {
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
        if shouldPersist && bindings.count != previousCount {
            persistBindings()
        }
    }

    private func persistBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else {
            log("SessionWindowRegistry failed to encode bindings")
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func loadBindings() -> [String: SessionWindowBinding] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: SessionWindowBinding].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
