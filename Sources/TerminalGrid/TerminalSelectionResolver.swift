import Foundation

// MARK: - 编排终端选择器（纯函数）
// 决定「对哪个终端 app 做编排」。三层优先级：
//   1. 用户手动指定（设置页选择器）——最高优先；
//   2. 自动：支持自动编排的终端里，按「持久化激活计数 + 当前在运行」选最近常用；
//   3. 兜底：无任何数据 → Terminal.app（macOS 自带，必然存在）。
// 支持面：Terminal.app = 完整（建窗/注入/tty/精确恢复）；iTerm2 = 部分（无 tty 映射、
// 自动恢复降级为只重建缺失格）；Warp/Ghostty 等暂无自动化通道 = 暂不支持。

/// 编排自动化支持级别
enum TerminalAutomationSupportLevel: Equatable {
    case full       // 建窗 / 注入 / tty / 精确恢复 全可用
    case partial    // 可建窗注入，但无 tty 映射，自动恢复降级
    case none       // 暂无自动化通道，无法编排
}

struct TerminalSelectionCandidate {
    let bundleID: String
    let name: String
    let support: TerminalAutomationSupportLevel
    /// 持久化激活次数（无记录为 0）
    let usageCount: Int
    /// 最近激活时间
    let lastUsedAt: Date?
    /// 当前是否在运行
    let isRunning: Bool
}

struct TerminalSelection {
    enum Source: Equatable {
        case manual
        case autoByUsage
        case autoDefault
    }

    let bundleID: String
    let name: String
    let source: Source
    /// 展示用理由，如 "最近常用（累计 42 次激活）"
    let reason: String
    let support: TerminalAutomationSupportLevel
}

enum TerminalSelectionResolver {

    /// 已知终端支持面（bundleID → 级别）。与 TerminalRegistry 名单互补：
    /// 名单内但不在表中的按 .none 处理。
    static let supportTable: [String: TerminalAutomationSupportLevel] = [
        "com.apple.Terminal": .full,
        "com.googlecode.iterm2": .partial,
        "dev.warp.Warp-Stable": .none,
        "com.mitchellh.ghostty": .none,
        "io.alacritty": .none,
        "net.kovidgoyal.kitty": .none,
        "com.github.wez.wezterm": .none,
        "com.electron.hyper": .none,
        "org.tabby": .none
    ]

    static func supportLevel(forBundleID bundleID: String) -> TerminalAutomationSupportLevel {
        supportTable[bundleID] ?? .none
    }

    /// 已知终端显示名（设置页/理由文案用）
    static let knownNames: [String: String] = [
        "com.apple.Terminal": "Terminal.app",
        "com.googlecode.iterm2": "iTerm2",
        "dev.warp.Warp-Stable": "Warp",
        "com.mitchellh.ghostty": "Ghostty",
        "io.alacritty": "Alacritty",
        "net.kovidgoyal.kitty": "kitty",
        "com.github.wez.wezterm": "wezterm",
        "com.electron.hyper": "Hyper",
        "org.tabby": "Tabby"
    ]

    /// - Parameters:
    ///   - manualBundleID: 用户手动指定的 bundleID；nil = 自动
    ///   - candidates: 全部已知终端的观测（usage/running 由调用方采集）
    static func resolve(manualBundleID: String?, candidates: [TerminalSelectionCandidate]) -> TerminalSelection {
        // 1. 手动指定优先（即便是 .none 支持级别也尊重用户选择，运行期会自然报错）
        if let manual = manualBundleID, !manual.isEmpty,
           let candidate = candidates.first(where: { $0.bundleID == manual }) {
            let reason: String
            switch candidate.support {
            case .full: reason = "手动指定"
            case .partial: reason = "手动指定（部分支持：无法读取 tty，自动恢复降级）"
            case .none: reason = "手动指定（暂无自动化通道，编排可能失败）"
            }
            return TerminalSelection(
                bundleID: candidate.bundleID,
                name: candidate.name,
                source: .manual,
                reason: reason,
                support: candidate.support
            )
        }

        // 2. 自动：支持编排（full/partial）的候选中，优先「当前在运行」，
        //    再按激活计数、最近使用排序
        let supported = candidates.filter { $0.support != .none }
        let ranked = supported.sorted { lhs, rhs in
            let lhsRun = lhs.isRunning ? 1 : 0
            let rhsRun = rhs.isRunning ? 1 : 0
            if lhsRun != rhsRun { return lhsRun > rhsRun }
            if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
            let lhsDate = lhs.lastUsedAt ?? .distantPast
            let rhsDate = rhs.lastUsedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.bundleID < rhs.bundleID
        }

        if let best = ranked.first, best.usageCount > 0 || best.isRunning {
            var reason = "自动：最近常用（累计 \(best.usageCount) 次激活"
            reason += best.isRunning ? "，当前在运行）" : "）"
            return TerminalSelection(
                bundleID: best.bundleID,
                name: best.name,
                source: .autoByUsage,
                reason: reason,
                support: best.support
            )
        }

        // 3. 兜底：无使用数据 → Terminal.app；理论上 candidates 必含它
        let fallback = ranked.first { $0.bundleID == "com.apple.Terminal" } ?? ranked.first
        guard let fallback else {
            return TerminalSelection(
                bundleID: "com.apple.Terminal",
                name: "Terminal.app",
                source: .autoDefault,
                reason: "默认 Terminal.app",
                support: .full
            )
        }
        return TerminalSelection(
            bundleID: fallback.bundleID,
            name: fallback.name,
            source: .autoDefault,
            reason: "暂无使用记录，默认 \(fallback.name)",
            support: fallback.support
        )
    }

    /// 检测警告：用户最常用的终端不在可编排范围时的提示（设置页展示）。
    /// usageRank 已按次数降序；返回nil = 无需提示。
    static func unsupportedFavoriteWarning(
        usageRank: [(bundleID: String, count: Int, lastAt: Date)],
        candidates: [TerminalSelectionCandidate],
        minimumCount: Int = 5
    ) -> String? {
        for entry in usageRank where entry.count >= minimumCount {
            guard let candidate = candidates.first(where: { $0.bundleID == entry.bundleID }) else { continue }
            if candidate.support == .none {
                return "检测到你最常用的终端是 \(candidate.name)（\(entry.count) 次激活），暂不支持自动编排；当前编排目标为支持编排的终端。"
            }
            return nil
        }
        return nil
    }
}
