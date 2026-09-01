// Tests/Standalone/ClaudeCodeWindowMatchTests.swift
// Verification: Claude Code 窗口定位纯决策（cwd→项目名提取 + 三级策略匹配）
// Mirrors: Sources/Window/WindowManager+Finding.swift
//         (projectName(fromCwd:) / matchClaudeCodeCandidate / ClaudeCodeMatchStrategy)
// Run: swift Tests/Standalone/ClaudeCodeWindowMatchTests.swift
//
// 背景（playbook 2.16a 第十九刀）：SessionStart autoFocus 的窗口定位决策曾内联在
// findClaudeCodeWindow 的 I/O 编排中。本刀抽出两个纯函数并穷尽分支：
// - projectName(fromCwd:)：trim 斜杠 → 按斜杠切分 → 取末段 → 小写；nil/空/全斜杠 → nil
// - matchClaudeCodeCandidate：策略 1（hostApp+项目名，projectName 非空才启用）
//   优先于策略 2（hostApp+标题含 "claude code"，大小写不敏感），均未中 → nil（调用方回退前台）。
// hostApp 判定以闭包注入（生产传 TerminalRegistry.isTerminalOrIDEApp），
// 本测试的被测对象是策略顺序与匹配条件本身。

import Foundation

// MARK: - Extracted pure logic

/// Mirrors WindowManager.WindowCandidate
struct MirrorWindowCandidate {
    let windowID: UInt32
    let appName: String
    let title: String
}

/// Mirrors WindowManager.ClaudeCodeMatchStrategy
enum MirrorClaudeCodeMatchStrategy: Equatable {
    case hostAppProjectName
    case hostAppClaudeCodeTitle
}

/// Mirrors WindowManager.projectName(fromCwd:)
func mirrorProjectName(fromCwd cwd: String?) -> String? {
    guard let cwd else { return nil }
    let trimmed = cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let last = trimmed.components(separatedBy: "/").last, !last.isEmpty else { return nil }
    return last.lowercased()
}

/// Mirrors WindowManager.matchClaudeCodeCandidate
func mirrorMatchClaudeCodeCandidate(
    _ candidates: [MirrorWindowCandidate],
    projectName: String?,
    isHostApp: (MirrorWindowCandidate) -> Bool
) -> (candidate: MirrorWindowCandidate, strategy: MirrorClaudeCodeMatchStrategy)? {
    if let projectName, !projectName.isEmpty,
       let match = candidates.first(where: { isHostApp($0) && $0.title.lowercased().contains(projectName) }) {
        return (match, .hostAppProjectName)
    }
    if let match = candidates.first(where: { isHostApp($0) && $0.title.lowercased().contains("claude code") }) {
        return (match, .hostAppClaudeCodeTitle)
    }
    return nil
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func cand(_ id: UInt32, _ app: String, _ title: String) -> MirrorWindowCandidate {
    MirrorWindowCandidate(windowID: id, appName: app, title: title)
}

let terminal = "iTerm2"
let editor = "TextEdit"

// MARK: 1. projectName(fromCwd:) — cwd 边界矩阵

print("1. projectName(fromCwd:)")

check("nil cwd → nil", mirrorProjectName(fromCwd: nil) == nil)
check("空串 → nil", mirrorProjectName(fromCwd: "") == nil)
check("根路径 / → nil", mirrorProjectName(fromCwd: "/") == nil)
check("双斜杠 // → nil", mirrorProjectName(fromCwd: "//") == nil)
check("常规路径 → 末段小写", mirrorProjectName(fromCwd: "/Users/cc/work/VibeFocus") == "vibefocus")
check("尾随斜杠 → 末段不变", mirrorProjectName(fromCwd: "/Users/cc/work/VibeFocus/") == "vibefocus")
check("多个尾随斜杠 → 末段不变", mirrorProjectName(fromCwd: "/Users/cc/work/VibeFocus///") == "vibefocus")
check("大写末段 → 小写归一", mirrorProjectName(fromCwd: "/Users/cc/work/BAR") == "bar")
check("内部空段 /a//b → 末段 b（切分不压缩空段，取 last 不受影响）",
      mirrorProjectName(fromCwd: "/a//b") == "b")
check("单段相对路径 → 自身", mirrorProjectName(fromCwd: "bar") == "bar")
check("带空格末段原样保留（仅小写化）",
      mirrorProjectName(fromCwd: "/Users/cc/My Proj") == "my proj")

// MARK: 2. matchClaudeCodeCandidate — 策略顺序与匹配条件

print("\n2. matchClaudeCodeCandidate")

do {
    let candidates = [cand(1, terminal, "my bar project"), cand(2, terminal, "claude code")]
    let r = mirrorMatchClaudeCodeCandidate(candidates, projectName: "bar", isHostApp: { $0.appName == terminal })
    check("策略 1 命中：hostApp + 标题含项目名（标题大小写不敏感）",
          r?.strategy == .hostAppProjectName && r?.candidate.windowID == 1)
}
do {
    let candidates = [cand(2, terminal, "claude code"), cand(3, terminal, "my bar project")]
    let r = mirrorMatchClaudeCodeCandidate(candidates, projectName: "bar", isHostApp: { $0.appName == terminal })
    check("策略 1 优先于策略 2：即使 claude code 标题排在前面",
          r?.strategy == .hostAppProjectName && r?.candidate.windowID == 3)
}
do {
    let candidates = [cand(2, terminal, "claude code")]
    let r = mirrorMatchClaudeCodeCandidate(candidates, projectName: nil, isHostApp: { $0.appName == terminal })
    check("projectName 为 nil → 跳过策略 1，策略 2 命中",
          r?.strategy == .hostAppClaudeCodeTitle && r?.candidate.windowID == 2)
}
do {
    let candidates = [cand(2, terminal, "claude code")]
    let r = mirrorMatchClaudeCodeCandidate(candidates, projectName: "", isHostApp: { $0.appName == terminal })
    check("projectName 为空串 → 同样跳过策略 1（isEmpty 分支）",
          r?.strategy == .hostAppClaudeCodeTitle)
}
do {
    let candidates = [cand(1, terminal, "unrelated title"), cand(2, terminal, "my CLAUDE CODE session")]
    let r = mirrorMatchClaudeCodeCandidate(candidates, projectName: "bar", isHostApp: { $0.appName == terminal })
    check("策略 1 未中 → 策略 2 兜底，标题大小写不敏感",
          r?.strategy == .hostAppClaudeCodeTitle && r?.candidate.windowID == 2)
}
do {
    let candidates = [cand(1, editor, "vibefocus")]
    let r = mirrorMatchClaudeCodeCandidate(candidates, projectName: "vibefocus", isHostApp: { $0.appName == terminal })
    check("标题命中但非 hostApp → 策略 1 不命中", r == nil)
}
do {
    let candidates = [cand(1, editor, "claude code")]
    let r = mirrorMatchClaudeCodeCandidate(candidates, projectName: nil, isHostApp: { $0.appName == terminal })
    check("claude code 标题但非 hostApp → 策略 2 不命中（整个匹配返回 nil）", r == nil)
}
do {
    let candidates = [cand(1, terminal, "claude-coded")]
    let r = mirrorMatchClaudeCodeCandidate(candidates, projectName: nil, isHostApp: { $0.appName == terminal })
    check("「claude-coded」不含「claude code」子串 → 不命中（子串语义锁定）", r == nil)
}
do {
    let candidates = [cand(7, terminal, "a claude code b"), cand(8, terminal, "another claude code")]
    let r = mirrorMatchClaudeCodeCandidate(candidates, projectName: nil, isHostApp: { $0.appName == terminal })
    check("多候选同中 → 取列表首位（CGWindowList 顺序语义）", r?.candidate.windowID == 7)
}
do {
    let r = mirrorMatchClaudeCodeCandidate([], projectName: "bar", isHostApp: { _ in true })
    check("空候选列表 → nil（调用方回退前台窗口）", r == nil)
}
do {
    // hostApp 判定注入：同一列表、不同谓词 → 结果随谓词走（策略逻辑与判定解耦的证据）
    let candidates = [cand(1, editor, "claude code")]
    let allPass = mirrorMatchClaudeCodeCandidate(candidates, projectName: nil, isHostApp: { _ in true })
    check("谓词注入生效：同一候选在宽松谓词下命中策略 2",
          allPass?.strategy == .hostAppClaudeCodeTitle && allPass?.candidate.windowID == 1)
}

// MARK: 3. 端到端组合 — 项目名提取喂给策略 1

print("\n3. 端到端组合")

do {
    let candidates = [cand(1, terminal, "vibe-focus — zsh"), cand(2, terminal, "claude code")]
    let p = mirrorProjectName(fromCwd: "/Users/cc/github/vibe-coding-labs/vibe-focus/")
    let r = mirrorMatchClaudeCodeCandidate(candidates, projectName: p, isHostApp: { $0.appName == terminal })
    check("cwd「…/vibe-focus/」→ 项目名 vibe-focus → 策略 1 命中尾随斜杠场景的窗口",
          p == "vibe-focus" && r?.strategy == .hostAppProjectName && r?.candidate.windowID == 1)
}
do {
    let candidates = [cand(1, terminal, "zsh"), cand(2, terminal, "claude code")]
    let p = mirrorProjectName(fromCwd: "/")
    let r = mirrorMatchClaudeCodeCandidate(candidates, projectName: p, isHostApp: { $0.appName == terminal })
    check("cwd 为根路径 → 项目名 nil → 策略 2 兜底命中 claude code 窗口",
          p == nil && r?.strategy == .hostAppClaudeCodeTitle && r?.candidate.windowID == 2)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
