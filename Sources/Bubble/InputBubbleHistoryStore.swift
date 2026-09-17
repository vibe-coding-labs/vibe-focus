import Foundation

// MARK: - 气泡输入历史（B195 数据环 + B196 状态/窗口归属/面板底座）
// 用户定案（2026-09-17）：没按回车、只要与默认文案不一致就算草稿——历史必须区分
// 「草稿 / 已提交」两种状态，并带窗口归属（面板默认按窗过滤，可切全部）。
// 用例：提交注入失败的 BUG 再现时，用户来历史里复制/回填，文本永不蒸发。
// 记录点（全会话结束点，零打字路径开销）：
// - inject 提交 → .submitted
// - dismiss / SIGTERM 收尾（脏文本）→ .draft
// - DraftStore 防抖 flush 镜像（onFlushNonBlank 接线）→ .draft（app 被强杀也有最近草稿）
// 消费点：恢复决策（窗草稿>手动兜底最近历史>前缀）、↑↓ 翻阅、历史面板（B196）。
// 持久化在 UserDefaults（JSON 数组，最新在前），容量与时效双约束。

/// 输入条目状态：草稿（未回车提交）/ 已提交（经注入通道发出）。
enum InputBubbleHistoryStatus: String, Codable, Equatable {
    case draft
    case submitted
}

struct InputBubbleHistoryEntry: Codable, Equatable {
    let text: String
    let at: Date
    /// 记录时的目标终端窗（CGWindowID）。legacy 数据无此字段=nil（只在「全部」里可见）。
    let windowID: UInt32?
    /// 记录时的窗标题快照（标题会变，展示用）。legacy 无=nil。
    let windowTitle: String?
    var status: InputBubbleHistoryStatus

    private enum CodingKeys: String, CodingKey {
        case text, at, windowID, windowTitle, status
    }

    init(
        text: String,
        at: Date,
        windowID: UInt32? = nil,
        windowTitle: String? = nil,
        status: InputBubbleHistoryStatus = .draft
    ) {
        self.text = text
        self.at = at
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.status = status
    }

    /// 宽松解码：B195 时代的旧条目没有 windowID/windowTitle/status 字段，
    /// 缺省补 nil/.draft（不拒解=旧数据不蒸发）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        at = try container.decode(Date.self, forKey: .at)
        windowID = try container.decodeIfPresent(UInt32.self, forKey: .windowID)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        status = try container.decodeIfPresent(InputBubbleHistoryStatus.self, forKey: .status) ?? .draft
    }
}

/// 历史过滤口径（B196 面板）：默认只看气泡当前绑定窗，可切全部。
enum InputBubbleHistoryFilter {
    enum Scope: Equatable {
        case currentWindow   // 本窗（默认）
        case all             // 全部
    }

    /// windowID=nil 的 legacy 条目只归「全部」。
    static func select(
        _ entries: [InputBubbleHistoryEntry],
        scope: Scope,
        currentWindowID: UInt32?
    ) -> [InputBubbleHistoryEntry] {
        guard scope == .currentWindow else { return entries }
        guard let currentWindowID else { return [] }
        return entries.filter { $0.windowID == currentWindowID }
    }
}

@MainActor
final class InputBubbleHistoryStore {
    static let shared = InputBubbleHistoryStore()

    private let defaults: UserDefaults
    private let storageKey = "inputBubbleHistory"
    /// 容量上限（超出淘汰最旧）。B196 升 200：历史成了可翻阅的面板数据源。
    private let capacity: Int
    /// 过期时长（输入历史比草稿留更久：草稿 7 天兜底 windowID 复用，历史 30 天是记忆兜底）
    private let maxAge: TimeInterval

    init(
        defaults: UserDefaults = .standard,
        capacity: Int = 200,
        maxAge: TimeInterval = 30 * 24 * 3600
    ) {
        self.defaults = defaults
        self.capacity = capacity
        self.maxAge = maxAge
    }

    /// 记录一条输入。空白文本忽略；与最新一条同文同窗去重/晋升（见 append）；
    /// 懒清理：记录时顺带 prune。
    func record(
        _ text: String,
        windowID: UInt32? = nil,
        windowTitle: String? = nil,
        status: InputBubbleHistoryStatus = .draft,
        now: Date = Date()
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let updated = Self.append(
            entries(),
            text: text,
            at: now,
            windowID: windowID,
            windowTitle: windowTitle,
            status: status
        )
        persist(Self.prune(updated, now: now, maxAge: maxAge, capacity: capacity))
    }

    /// 按 at 时间戳删除单条（面板 ✕）。找不到（已过期清理等）静默。
    func remove(at id: Date) {
        let filtered = entries().filter { $0.at != id }
        guard filtered.count != entries().count else { return }
        persist(filtered)
    }

    func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    /// 最新一条（恢复决策兜底用）；无记录或全空白返回 nil。
    func latestEntry() -> InputBubbleHistoryEntry? {
        entries().first
    }

    /// 全部历史（最新在前），↑↓ 翻阅与面板消费。
    func entries() -> [InputBubbleHistoryEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([InputBubbleHistoryEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    // MARK: 纯函数（Runner 直测）

    /// 追加到最前，头部合并规则（只看最新一条，更老条目保持原样）：
    /// - 同文 + 同窗 + 草稿→已提交 → 原地晋升（一次输入旅程一条时间线）；
    /// - 同文 + 同窗其余组合（同状态刷新 / 已提交头部遇草稿回写）→ 保持头部状态
    ///   只刷时间戳（已提交不被降级，↑↓ 翻阅回写历史条目不产生草稿残影）；
    /// - 同文但异窗 → 新条目（不同窗各归各的时间线）。
    static func append(
        _ existing: [InputBubbleHistoryEntry],
        text: String,
        at: Date,
        windowID: UInt32? = nil,
        windowTitle: String? = nil,
        status: InputBubbleHistoryStatus = .draft
    ) -> [InputBubbleHistoryEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let head = existing.first,
           head.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed,
           head.windowID == windowID {
            switch (head.status, status) {
            case (.draft, .submitted):
                return [InputBubbleHistoryEntry(
                    text: text, at: at, windowID: head.windowID,
                    windowTitle: windowTitle ?? head.windowTitle, status: .submitted
                )] + existing.dropFirst()
            default:
                return [InputBubbleHistoryEntry(
                    text: text, at: at, windowID: head.windowID,
                    windowTitle: windowTitle ?? head.windowTitle, status: head.status
                )] + existing.dropFirst()
            }
        }
        return [InputBubbleHistoryEntry(
            text: text, at: at, windowID: windowID,
            windowTitle: windowTitle, status: status
        )] + existing
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
