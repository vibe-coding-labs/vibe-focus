// Tests/Standalone/TerminalSelectionLogicTests.swift
// Verification: 编排终端选择器（手动优先 / 自动按最近常用 / 运行中加成 / 兜底）
//               + 使用量表（记录/排序/常用非支持警告）纯逻辑
// Mirrors: Sources/TerminalGrid/TerminalSelectionResolver.swift, Sources/TerminalGrid/TerminalUsageTracker.swift
// Run: swift Tests/Standalone/TerminalSelectionLogicTests.swift

import Foundation

// MARK: - Mirrored logic

struct TerminalUsageEntry: Codable, Equatable {
    var count: Int
    var lastAt: Date
}

struct TerminalUsageTable {
    var entries: [String: TerminalUsageEntry] = [:]

    mutating func record(bundleID: String, at date: Date = Date()) {
        if var entry = entries[bundleID] {
            entry.count += 1
            entry.lastAt = max(entry.lastAt, date)
            entries[bundleID] = entry
        } else {
            entries[bundleID] = TerminalUsageEntry(count: 1, lastAt: date)
        }
    }

    func ranked(minCount: Int = 1, now: Date = Date(), halfLifeDays: Double = 14) -> [(bundleID: String, count: Int, lastAt: Date)] {
        let half = halfLifeDays * 24 * 3600
        return entries
            .filter { $0.value.count >= minCount }
            .map { (bundleID: $0.key, count: $0.value.count, lastAt: $0.value.lastAt) }
            .sorted {
                let lw = Double($0.count) * pow(0.5, max(0, now.timeIntervalSince($0.lastAt)) / half)
                let rw = Double($1.count) * pow(0.5, max(0, now.timeIntervalSince($1.lastAt)) / half)
                if lw != rw { return lw > rw }
                return $0.lastAt > $1.lastAt
            }
    }
}

enum Support { case full, partial, none }

struct Candidate {
    let bundleID: String
    let name: String
    let support: Support
    let usageCount: Int
    let lastUsedAt: Date?
    let isRunning: Bool
}

enum SelectionSource: Equatable { case manual, autoByUsage, autoDefault }

struct Selection: Equatable {
    let bundleID: String
    let source: SelectionSource
}

func resolve(manual: String?, candidates: [Candidate]) -> Selection {
    if let manual, !manual.isEmpty,
       let c = candidates.first(where: { $0.bundleID == manual }) {
        return Selection(bundleID: c.bundleID, source: .manual)
    }
    let supported = candidates.filter { $0.support != .none }
    let ranked = supported.sorted { lhs, rhs in
        let lr = lhs.isRunning ? 1 : 0
        let rr = rhs.isRunning ? 1 : 0
        if lr != rr { return lr > rr }
        if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
        let ld = lhs.lastUsedAt ?? .distantPast
        let rd = rhs.lastUsedAt ?? .distantPast
        if ld != rd { return ld > rd }
        return lhs.bundleID < rhs.bundleID
    }
    if let best = ranked.first, best.usageCount > 0 || best.isRunning {
        return Selection(bundleID: best.bundleID, source: .autoByUsage)
    }
    let fallback = ranked.first { $0.bundleID == "com.apple.Terminal" } ?? ranked.first
    guard let f = fallback else {
        return Selection(bundleID: "com.apple.Terminal", source: .autoDefault)
    }
    return Selection(bundleID: f.bundleID, source: .autoDefault)
}

func unsupportedFavoriteWarning(
    usageRank: [(bundleID: String, count: Int, lastAt: Date)],
    candidates: [Candidate],
    minimumCount: Int = 5
) -> String? {
    for entry in usageRank where entry.count >= minimumCount {
        guard let c = candidates.first(where: { $0.bundleID == entry.bundleID }) else { continue }
        if c.support == .none { return c.name }
        return nil
    }
    return nil
}

// MARK: - Harness

var passed = 0
var failed = 0
func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

let TERMINAL = "com.apple.Terminal"
let ITERM = "com.googlecode.iterm2"
let WARP = "dev.warp.Warp-Stable"

func cand(_ id: String, usage: Int, running: Bool, support: Support, name: String = "") -> Candidate {
    Candidate(bundleID: id, name: name, support: support, usageCount: usage,
              lastUsedAt: usage > 0 ? Date(timeIntervalSince1970: Double(usage)) : nil, isRunning: running)
}

let allCandidates = [
    cand(TERMINAL, usage: 0, running: true, support: .full, name: "Terminal.app"),
    cand(ITERM, usage: 0, running: false, support: .partial, name: "iTerm2"),
    cand(WARP, usage: 0, running: false, support: .none, name: "Warp")
]

// MARK: - 选择器

check("选择: 手动指定优先（即使用量更高的是别家）",
      resolve(manual: TERMINAL, candidates: [
        cand(TERMINAL, usage: 2, running: false, support: .full),
        cand(ITERM, usage: 99, running: true, support: .partial)
      ]).source == .manual)

check("选择: 自动 + 无记录 + 都在运行 → 运行中优先",
      resolve(manual: nil, candidates: allCandidates).bundleID == TERMINAL)

check("选择: 自动按激活计数选最常用",
      resolve(manual: nil, candidates: [
        cand(TERMINAL, usage: 3, running: true, support: .full),
        cand(ITERM, usage: 30, running: true, support: .partial)
      ]).bundleID == ITERM)

check("选择: 在运行加成压过少量用量差",
      resolve(manual: nil, candidates: [
        cand(TERMINAL, usage: 10, running: true, support: .full),
        cand(ITERM, usage: 12, running: false, support: .partial)
      ]).bundleID == TERMINAL)

check("选择: 不支持编排的常用终端不参与自动选择",
      resolve(manual: nil, candidates: [
        cand(TERMINAL, usage: 2, running: false, support: .full),
        cand(WARP, usage: 100, running: true, support: .none)
      ]).bundleID == TERMINAL)

check("选择: 全空 → 兜底 Terminal.app",
      resolve(manual: nil, candidates: allCandidates.map {
        cand($0.bundleID, usage: 0, running: false, support: $0.support)
      }).bundleID == TERMINAL)

check("选择: 手动指定未知终端 → 兜底自动（不空引用）",
      resolve(manual: "com.unknown.app", candidates: allCandidates).bundleID != "")

// MARK: - 使用量表

var table = TerminalUsageTable()
table.record(bundleID: ITERM)
table.record(bundleID: ITERM)
table.record(bundleID: ITERM, at: Date(timeIntervalSince1970: 100))
table.record(bundleID: TERMINAL, at: Date(timeIntervalSince1970: 200))
check("量表: 计数累加", table.entries[ITERM]?.count == 3 && table.entries[TERMINAL]?.count == 1)
check("量表: 排序次数优先", table.ranked().first?.bundleID == ITERM)
check("量表: minCount 过滤噪声", table.ranked(minCount: 5).isEmpty)

// 半衰期衰减：老高频 vs 新低频（"最近常用"要求近期使用权重更高）
var decayTable = TerminalUsageTable()
let now = Date()
let oldDay = now.addingTimeInterval(-60 * 24 * 3600)
for _ in 0..<10 { decayTable.record(bundleID: "old-app", at: oldDay) }
decayTable.record(bundleID: "new-app", at: now)
check("衰减: 60 天前的 10 次 降权于 今天的 1 次（10×0.051 < 1）",
      decayTable.ranked(now: now, halfLifeDays: 14).first?.bundleID == "new-app")
decayTable.record(bundleID: "old-app", at: now)
check("衰减: 老终端重新激活即回升",
      decayTable.ranked(now: now, halfLifeDays: 14).first?.bundleID == "old-app")

// MARK: - 常用非支持警告

let warningRank = [(bundleID: WARP, count: 42, lastAt: Date()), (bundleID: TERMINAL, count: 7, lastAt: Date())]
check("警告: 最常用为 Warp（不可编排）→ 提示", unsupportedFavoriteWarning(usageRank: warningRank, candidates: allCandidates) == "Warp")
let okRank = [(bundleID: ITERM, count: 42, lastAt: Date()), (bundleID: WARP, count: 30, lastAt: Date())]
check("警告: 最常用可编排 → 无提示", unsupportedFavoriteWarning(usageRank: okRank, candidates: allCandidates) == nil)
check("警告: 低于最小次数不提示", unsupportedFavoriteWarning(usageRank: warningRank, candidates: allCandidates, minimumCount: 100) == nil)

print("")
print("TerminalSelectionLogicTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
