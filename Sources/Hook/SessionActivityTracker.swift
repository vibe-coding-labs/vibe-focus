// SessionActivityTracker.swift
// VibeFocus — 会话活动追踪（B202 live 会话面板的数据源）
//
// SessionWindowRegistry 回答「会话绑在哪个窗」，本类回答「会话此刻在哪个阶段」：
// 从 hook 事件流派生 running/waiting/done 等状态。内存态供 app 内设置页面板，
// 同时原子持久化到 ~/.vibefocus/session-activity.json——--diagnose 是独立 CLI
// 进程，读内存单例永远空白（真机首验抓到的坑），读文件才能看到 running app 的
// 实时状态；app 重启也由此延续 ≤24h 的最近状态。容量有界（128 会话+24h 过期）。
//
// 派生语义（最后一个事件说了算）：
//   UserPromptSubmit → running（用户提交=Claude 开工）
//   Notification     → waiting（B196：等权限确认/空闲等待）
//   Stop             → done（本轮完成，B192 语义=回复结束）
//   SessionStart     → bound（已绑定，尚未开工）
//   SessionEnd       → ended（会话结束）

import Foundation

enum SessionLiveStatus: String, Equatable, CaseIterable {
    case running
    case waiting
    case done
    case bound
    case ended

    /// 面板徽章/诊断行共用文案（单一事实源）。
    var label: String {
        switch self {
        case .running: return "运行中"
        case .waiting: return "等待输入"
        case .done: return "已完成"
        case .bound: return "已绑定"
        case .ended: return "已结束"
        }
    }

    /// 面板排序权重：等输入的最前（用户最该看），已结束的最后。
    var sortPriority: Int {
        switch self {
        case .waiting: return 0
        case .running: return 1
        case .bound: return 2
        case .done: return 3
        case .ended: return 4
        }
    }
}

struct SessionActivity: Equatable {
    let lastEvent: ClaudeHookEventType
    let at: Date
    let lastCode: String?
}

@MainActor
final class SessionActivityTracker: ObservableObject {
    static let shared = SessionActivityTracker()

    /// 容量上限：超过后淘汰最旧的会话（8+ 并发是常态，128 足够宽裕）。
    static let maxSessions = 128
    /// 条目最大年龄：超龄条目在 prune 时清除（状态是实时信号，隔天即失效）。
    static let maxAge: TimeInterval = 24 * 3600
    /// 持久化路径：--diagnose（独立 CLI 进程）与 app 重启都要能读回最近状态——
    /// 纯内存会让「面板」在真正需要它的排障现场（--diagnose）永远空白。
    nonisolated static var storeURL: URL {
        URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".vibefocus/session-activity.json"))
    }

    @Published private(set) var activities: [String: SessionActivity] = [:]

    private init() {
        // 进程内冷启动回灌：上次运行的最近状态（≤24h）即刻可见。
        // CLI（Runner）无 bundle id 不读不写（防测试污染真身文件）。
        guard Self.isPersistable else { return }
        if let data = try? Data(contentsOf: Self.storeURL),
           let restored = Self.parseActivities(data: data) {
            activities = restored
            prune(now: Date())
        }
    }

    /// app（有 bundle id）才持久化；Runner CLI 读不写防污染。
    static var isPersistable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func record(sessionID: String, event: ClaudeHookEventType, code: String?, at: Date = Date()) {
        guard !sessionID.isEmpty else { return }
        activities[sessionID] = SessionActivity(lastEvent: event, at: at, lastCode: code)
        prune(now: at)
        persistAsync()
    }

    func activity(for sessionID: String) -> SessionActivity? {
        activities[sessionID]
    }

    /// 状态派生唯一入口在 SessionPanelLogic（纯函数命名空间，非隔离可直测）。

    /// 双重剪枝：超龄先清，再按容量淘汰最旧（事件时间序，非插入序）。
    func prune(now: Date, maxAge: TimeInterval = SessionActivityTracker.maxAge, maxSessions: Int = SessionActivityTracker.maxSessions) {
        for (id, activity) in activities where now.timeIntervalSince(activity.at) > maxAge {
            activities.removeValue(forKey: id)
        }
        while activities.count > maxSessions {
            if let oldest = activities.min(by: { $0.value.at < $1.value.at })?.key {
                activities.removeValue(forKey: oldest)
            } else {
                break
            }
        }
    }

    /// 测试隔离缝（Runner 共享单例域，用后清场）。
    func resetForTesting() {
        activities = [:]
    }

    // MARK: - 持久化（跨进程供 --diagnose 读取；原子写、后台队列、不占主线程）

    private func persistAsync() {
        guard Self.isPersistable else { return }
        let snapshot = activities
        Task.detached(priority: .utility) {
            Self.writeToFile(snapshot: snapshot)
        }
    }

    nonisolated static func writeToFile(snapshot: [String: SessionActivity]) {
        guard let data = encodeActivities(activities: snapshot) else { return }
        let url = storeURL
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-session-activity.json")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data) else { return }
        try? FileManager.default.removeItem(atPath: url.path)
        try? FileManager.default.moveItem(atPath: tmp.path, toPath: url.path)
    }

    /// 纯编码（Runner 直测）：ISO8601 时间 + 紧凑 JSON。
    nonisolated static func encodeActivities(activities: [String: SessionActivity]) -> Data? {
        let df = ISO8601DateFormatter()
        let payload: [String: [String: String]] = activities.mapValues { a in
            var entry = ["event": a.lastEvent.rawValue, "at": df.string(from: a.at)]
            if let code = a.lastCode { entry["code"] = code }
            return entry
        }
        return try? JSONSerialization.data(withJSONObject: ["version": 1, "sessions": payload])
    }

    /// 纯解码（Runner 直测）：坏行/缺字段条目跳过，绝不 throw。
    nonisolated static func parseActivities(data: Data) -> [String: SessionActivity]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [String: [String: Any]] else { return nil }
        let df = ISO8601DateFormatter()
        var out: [String: SessionActivity] = [:]
        for (id, entry) in sessions {
            guard let eventRaw = entry["event"] as? String,
                  let event = ClaudeHookEventType(rawValue: eventRaw),
                  let atString = entry["at"] as? String,
                  let at = df.date(from: atString) else { continue }
            out[id] = SessionActivity(lastEvent: event, at: at, lastCode: entry["code"] as? String)
        }
        return out
    }

    /// --diagnose 等 CLI 进程读取最近状态（只读文件，不触内存单例）。
    nonisolated static func loadPersisted() -> [String: SessionActivity] {
        guard let data = try? Data(contentsOf: storeURL) else { return [:] }
        return parseActivities(data: data) ?? [:]
    }
}
