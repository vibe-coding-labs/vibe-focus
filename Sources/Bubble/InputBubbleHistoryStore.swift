import Foundation

// MARK: - 气泡输入历史（B195 数据环 + B196 状态/窗口归属/面板底座 + B203 搜索/翻阅口径/批量清理）
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

    /// 搜索过滤（B203）：大小写/变音符/全半角折叠后的子串匹配，命中正文或窗标题
    /// 快照任一即保留。空白查询=不过滤（原样返回）。
    static func search(
        _ entries: [InputBubbleHistoryEntry],
        query: String
    ) -> [InputBubbleHistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let key = fold(trimmed)
        return entries.filter { entry in
            fold(entry.text).contains(key)
                || (entry.windowTitle.map { fold($0).contains(key) } ?? false)
        }
    }

    /// ↑↓ 翻阅口径（B203）：与面板默认一致优先本窗；本窗无任何历史时回落全部
    /// （保留 B195 的跨窗兜底——窗一关一开 CGWindowID 换新后，翻阅与恢复不至于清零）。
    static func navEntries(
        _ entries: [InputBubbleHistoryEntry],
        currentWindowID: UInt32?
    ) -> [InputBubbleHistoryEntry] {
        let perWindow = select(entries, scope: .currentWindow, currentWindowID: currentWindowID)
        return perWindow.isEmpty ? entries : perWindow
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
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

    /// 批量删除（B203 面板「清空本视图」）：谓词命中的全部移除，一条未命中则静默。
    func remove(where shouldRemove: (InputBubbleHistoryEntry) -> Bool) {
        let before = entries()
        let filtered = before.filter { !shouldRemove($0) }
        guard filtered.count != before.count else { return }
        persist(filtered)
    }

    func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    /// 最新一条（恢复决策兜底用）；无记录或全空白返回 nil。
    func latestEntry() -> InputBubbleHistoryEntry? {
        entries().first
    }

    /// 最新一条**未提交草稿**（B208 恢复决策兜底专用）：已提交内容绝不自动回填
    /// （用户 2026-09-18 定案——回车发出过的文本再填回来是打扰）。↑↓ 翻阅/
    /// 历史面板/⌘Y 填充是显式操作，仍可取已提交条目（走 entries()/面板过滤）。
    func latestDraftEntry() -> InputBubbleHistoryEntry? {
        Self.latestDraft(in: entries())
    }

    /// 纯函数（Runner 直测）：条目数组（最新在前）里第一条 draft 状态条目；
    /// 全是已提交/空数组返回 nil。
    static func latestDraft(in entries: [InputBubbleHistoryEntry]) -> InputBubbleHistoryEntry? {
        entries.first { $0.status == .draft }
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

    /// 近端合并窗深：同文同窗条目在此深度内命中即刷新置顶，不再新增。
    /// 依据：↑↓ 翻阅每步都同步草稿（B195 设计），flush 镜像把路过的文本逐条记账，
    /// 只看头部的旧规则让来回翻阅在头部两侧交替堆重复对（B203 真机 smoke 实锤：
    /// ↑↓ 各 2 次造出 3 对重复）；8 的窗深覆盖往返翻阅+穿插打字的回看距离。
    static let mergeLookback = 8

    /// 追加规则：近端（前 mergeLookback 条）内同文+同窗 → 命中条刷新置顶
    /// （草稿→已提交晋升；已提交不被草稿降级；时间戳/窗名快照刷新为本次值）；
    /// 近端无命中 → 新条目插到最前（不同窗各归各的时间线，更老条目保持原样）。
    static func append(
        _ existing: [InputBubbleHistoryEntry],
        text: String,
        at: Date,
        windowID: UInt32? = nil,
        windowTitle: String? = nil,
        status: InputBubbleHistoryStatus = .draft
    ) -> [InputBubbleHistoryEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = existing.prefix(mergeLookback).firstIndex(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
                && $0.windowID == windowID
        }) {
            let hit = existing[idx]
            let merged: InputBubbleHistoryStatus = hit.status == .submitted ? .submitted : status
            var updated = existing
            updated.remove(at: idx)
            updated.insert(InputBubbleHistoryEntry(
                text: text, at: at, windowID: hit.windowID,
                windowTitle: windowTitle ?? hit.windowTitle, status: merged
            ), at: 0)
            return updated
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
