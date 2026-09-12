import Foundation

// MARK: - 气泡输入草稿（B162）
// 输入跟目标窗绑定：气泡意外关闭/切走后重开，打到一半的内容还在该窗的气泡里。
// 持久化在 UserDefaults（JSON {windowID: {text, at}}），写入时惰性清理——
// CGWindowID 可能被系统回收复用，容量与时效双约束兜底串味；提交成功即清。

struct InputBubbleDraftEntry: Codable, Equatable {
    let text: String
    let at: Date
}

@MainActor
final class InputBubbleDraftStore {
    static let shared = InputBubbleDraftStore()

    private let defaults: UserDefaults
    private let storageKey = "inputBubbleDrafts"
    /// 容量上限（超出淘汰最旧）
    private let capacity: Int
    /// 过期时长（CGWindowID 复用周期无 API 可查，7 天经验值兜底）
    private let maxAge: TimeInterval
    /// B178 打字防抖：每个按键都走「JSON decode + prune + encode + defaults 写」
    /// 在主线程排队（长草稿时毫秒级×每键），打字期间与 hook 窗口作业叠加放大卡顿。
    /// 改为未落盘编辑先进 pendingEdits（读取方优先看 pending，语义不变），
    /// 静默 300ms 后一次落盘。
    private let saveDebounceInterval: TimeInterval
    private var pendingEdits: [UInt32: String] = [:]
    private var flushWorkItem: DispatchWorkItem?

    init(
        defaults: UserDefaults = .standard,
        capacity: Int = 32,
        maxAge: TimeInterval = 7 * 24 * 3600,
        saveDebounceInterval: TimeInterval = 0.3
    ) {
        self.defaults = defaults
        self.capacity = capacity
        self.maxAge = maxAge
        self.saveDebounceInterval = saveDebounceInterval
    }

    func draft(for windowID: UInt32) -> String? {
        // 未落盘的编辑优先（save 已进 pending 但尚未 flush 的窗口）。
        if let pending = pendingEdits[windowID] {
            return pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : pending
        }
        return entries()[key(windowID)]?.text
    }

    /// 保存/更新草稿；空白文本等价于清除（不留空串条目）。
    /// 防抖语义：文本先进 pendingEdits 立即可读，落盘延后 300ms 静默批处理。
    func save(_ text: String, for windowID: UInt32, now: Date = Date()) {
        pendingEdits[windowID] = text
        scheduleFlush(now: now)
    }

    func clear(for windowID: UInt32) {
        // 提交成功清草稿：必须同时丢弃未落盘编辑，否则延后 flush 会复活已清草稿。
        pendingEdits.removeValue(forKey: windowID)
        var all = entries()
        guard all.removeValue(forKey: key(windowID)) != nil else { return }
        persist(all)
    }

    /// 防抖落盘调度（单飞行 workitem，新保存重置计时）。
    private func scheduleFlush(now: Date) {
        flushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushPending()
        }
        flushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: item)
    }

    /// 把 pendingEdits 批量落盘（flush 时窗口可能已提交清稿——pending 已被
    /// clear 移除，天然不会复活）。
    func flushPending(now: Date = Date()) {
        guard !pendingEdits.isEmpty else { return }
        var all = entries()
        for (windowID, text) in pendingEdits {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                all.removeValue(forKey: key(windowID))
            } else {
                all[key(windowID)] = InputBubbleDraftEntry(text: text, at: now)
            }
        }
        pendingEdits.removeAll()
        let pruned = Self.prune(all, now: now, maxAge: maxAge, capacity: capacity)
        persist(pruned)
    }

    // MARK: 存取

    private func key(_ windowID: UInt32) -> String { String(windowID) }

    private func entries() -> [String: InputBubbleDraftEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: InputBubbleDraftEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func persist(_ entries: [String: InputBubbleDraftEntry]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }

    // MARK: 惰性清理（纯函数，Runner 直测）

    /// 过期剔除 → 容量裁剪（保留 at 最新的 capacity 条）。
    static func prune(
        _ entries: [String: InputBubbleDraftEntry],
        now: Date,
        maxAge: TimeInterval,
        capacity: Int
    ) -> [String: InputBubbleDraftEntry] {
        let alive = entries.filter { now.timeIntervalSince($0.value.at) < maxAge }
        guard alive.count > capacity else { return alive }
        let sorted = alive.sorted { $0.value.at > $1.value.at }
        return Dictionary(uniqueKeysWithValues: sorted.prefix(capacity).map { ($0.key, $0.value) })
    }
}
