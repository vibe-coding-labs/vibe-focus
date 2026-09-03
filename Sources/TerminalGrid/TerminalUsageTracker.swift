import AppKit
import Foundation

// MARK: - 终端使用量追踪
// 「自动：最近常用」的数据源。监听 NSWorkspace 应用激活事件，对已知终端
// （TerminalRegistry 名单）累计激活次数 + 最近激活时间，持久化在 UserDefaults。
// 纯逻辑（表操作）与 AppKit 观测分离：表操作可完整单测。

/// 单个终端的使用统计
struct TerminalUsageEntry: Codable, Equatable {
    var count: Int
    var lastAt: Date
}

/// 使用量表（bundleID → 统计）。Codable JSON 存 UserDefaults。
struct TerminalUsageTable: Codable, Equatable {
    var entries: [String: TerminalUsageEntry] = [:]

    static let userDefaultsKey = "terminalUsageTable"

    /// 记录一次激活（幂等累加）
    mutating func record(bundleID: String, at date: Date = Date()) {
        if var entry = entries[bundleID] {
            entry.count += 1
            entry.lastAt = date
            entries[bundleID] = entry
        } else {
            entries[bundleID] = TerminalUsageEntry(count: 1, lastAt: date)
        }
    }

    /// 按激活次数降序（同次数按最近优先）。minCount 过滤掉噪声。
    func ranked(minCount: Int = 1) -> [(bundleID: String, count: Int, lastAt: Date)] {
        entries
            .filter { $0.value.count >= minCount }
            .map { (bundleID: $0.key, count: $0.value.count, lastAt: $0.value.lastAt) }
            .sorted {
                $0.count != $1.count ? $0.count > $1.count : $0.lastAt > $1.lastAt
            }
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decode(_ data: Data) -> TerminalUsageTable? {
        try? JSONDecoder().decode(TerminalUsageTable.self, from: data)
    }
}

// MARK: - 激活观测（AppKit 侧）

@MainActor
final class TerminalUsageTracker {
    static let shared = TerminalUsageTracker()

    private var observer: Any?
    private(set) var table: TerminalUsageTable

    init(table: TerminalUsageTable? = nil) {
        self.table = table ?? Self.loadTable()
    }

    /// 应用启动时调用一次；重复调用幂等
    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // 先在块外取值（Notification 非 Sendable），只把 String 带进隔离域
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            // queue: .main 保证主线程；显式 assumeIsolated 满足 Sendable 检查
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let bundleID, TerminalRegistry.isTerminalBundleID(bundleID) else {
                    return
                }
                self.table.record(bundleID: bundleID)
                Self.saveTable(self.table)
            }
        }
        log("[TerminalUsage] tracker started", level: .debug)
    }

    static func loadTable() -> TerminalUsageTable {
        guard let data = UserDefaults.standard.data(forKey: TerminalUsageTable.userDefaultsKey),
              let table = TerminalUsageTable.decode(data) else {
            return TerminalUsageTable()
        }
        return table
    }

    static func saveTable(_ table: TerminalUsageTable) {
        if let data = table.encoded() {
            UserDefaults.standard.set(data, forKey: TerminalUsageTable.userDefaultsKey)
        }
    }
}
