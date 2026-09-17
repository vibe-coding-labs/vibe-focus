import Foundation

// MARK: - 气泡输入历史（B195）
// 「气泡不小心搞没了，再打开就被重置」的根治底座：草稿按 CGWindowID 绑定有结构性
// 盲区——终端窗一关一开 windowID 换新，旧草稿成孤儿永远读不回；跟随改绑/换窗唤起
// 时草稿也不跨窗。全局输入历史环是跨窗、跨重启的最后一道网：
// - 记录点 = 提交注入、气泡关闭（含改绑 dismiss）、SIGTERM 收尾——都是会话结束点，
//   不在打字路径上（无每键开销）；
// - 消费点 = 气泡打开时的恢复决策（InputBubbleDraftRestorePlan：窗草稿优先，
//   手动唤起兜底最近历史）与 ↑↓ 历史翻阅（InputBubbleHistoryNavPlan）。
// 持久化在 UserDefaults（JSON 数组，最新在前），容量与时效双约束。

struct InputBubbleHistoryEntry: Codable, Equatable {
    let text: String
    let at: Date
}

@MainActor
final class InputBubbleHistoryStore {
    static let shared = InputBubbleHistoryStore()

    private let defaults: UserDefaults
    private let storageKey = "inputBubbleHistory"
    /// 容量上限（超出淘汰最旧）
    private let capacity: Int
    /// 过期时长（输入历史比草稿留更久：草稿 7 天兜底 windowID 复用，历史 30 天是记忆兜底）
    private let maxAge: TimeInterval

    init(
        defaults: UserDefaults = .standard,
        capacity: Int = 50,
        maxAge: TimeInterval = 30 * 24 * 3600
    ) {
        self.defaults = defaults
        self.capacity = capacity
        self.maxAge = maxAge
    }

    /// 记录一条输入（会话结束点调用）。空白文本忽略；与最新一条同文去重
    /// （连续关闭/提交同稿不刷时间线）；懒清理：记录时顺带 prune。
    func record(_ text: String, now: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let updated = Self.append(entries(), text: text, at: now)
        persist(Self.prune(updated, now: now, maxAge: maxAge, capacity: capacity))
    }

    /// 最新一条（恢复决策兜底用）；无记录或全空白返回 nil。
    func latestEntry() -> InputBubbleHistoryEntry? {
        entries().first
    }

    /// 全部历史（最新在前），↑↓ 翻阅消费。
    func entries() -> [InputBubbleHistoryEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([InputBubbleHistoryEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    // MARK: 纯函数（Runner 直测）

    /// 追加一条到最前；与最新一条同文（去空白比对）只刷新时间戳不重复入列。
    static func append(
        _ existing: [InputBubbleHistoryEntry],
        text: String,
        at: Date
    ) -> [InputBubbleHistoryEntry] {
        if let first = existing.first,
           first.text.trimmingCharacters(in: .whitespacesAndNewlines)
               == text.trimmingCharacters(in: .whitespacesAndNewlines) {
            return [InputBubbleHistoryEntry(text: first.text, at: at)] + existing.dropFirst()
        }
        return [InputBubbleHistoryEntry(text: text, at: at)] + existing
    }

    /// 过期剔除 → 容量裁剪（保最新 capacity 条）。
    static func prune(
        _ entries: [InputBubbleHistoryEntry],
        now: Date,
        maxAge: TimeInterval,
        capacity: Int
    ) -> [InputBubbleHistoryEntry] {
        let alive = entries.filter { now.timeIntervalSince($0.at) < maxAge }
        guard alive.count > capacity else { return alive }
        return Array(alive.prefix(capacity))
    }

    private func persist(_ entries: [InputBubbleHistoryEntry]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
