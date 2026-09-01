// Tests/Standalone/HookSettingsCompositionTests.swift
// Verification: Claude settings.json hooks 字段编排纯函数（写者/识别者/清理者共用判据）
// Mirrors: Sources/Hook/HookSettingsComposition.swift
// Run: swift Tests/Standalone/HookSettingsCompositionTests.swift
//
// 背景（playbook 2.16a 第十七刀）："VibeFocus hook 条目长什么样"的判据曾三处各写一份
// （install 清理 / isHookInstalled / 卸载），且 install 在开关关闭时 removeValue 整键删除——
// 连带清掉用户自装的同事件 hook（真 bug）。本套纯函数收敛判据为唯一事实源，
// 终态语义 = "只动自己的条目，外部 hook 一律保留"。本测试对每个分支穷尽覆盖，
// 并以防回退断言锁定整键删除 bug 的修复。

import Foundation

// MARK: - Extracted pure logic

/// Mirrors HookSettingsComposition
enum MirrorHookSettingsComposition {

    /// VibeFocus hook 条目识别唯一判据：url 精确相等 OR command 含脚本路径
    static func isVibeFocusHook(_ hook: [String: Any], targetURL: String, scriptPath: String) -> Bool {
        if let url = hook["url"] as? String, url == targetURL { return true }
        if let command = hook["command"] as? String, command.contains(scriptPath) { return true }
        return false
    }

    /// 单事件 entry 数组移除 VibeFocus 条目。entry 无 "hooks" 数组视为外部条目，原样保留。
    static func stripVibeFocusEntries(from entries: [[String: Any]], targetURL: String, scriptPath: String) -> (kept: [[String: Any]], removed: Int) {
        var removed = 0
        let kept = entries.filter { entry in
            guard let hookList = entry["hooks"] as? [[String: Any]] else { return true }
            let isOurs = hookList.contains { isVibeFocusHook($0, targetURL: targetURL, scriptPath: scriptPath) }
            if isOurs { removed += 1 }
            return !isOurs
        }
        return (kept, removed)
    }

    /// 期望 hooks 终态：现有键 ∪ 生成键全扫描，摘除全部 VibeFocus 条目后并入 generated。
    /// 外部 hook 一律保留；本 app 不再声明的事件，键随外部条目去留（全空才删键）。
    static func composeDesiredHooks(existing: [String: Any], generated: [String: Any], targetURL: String, scriptPath: String) -> [String: Any] {
        var result = existing
        for key in Set(result.keys).union(generated.keys) {
            let generatedEntries = (generated[key] as? [[String: Any]]) ?? []
            let existingEntries = (result[key] as? [[String: Any]]) ?? []
            let stripped = stripVibeFocusEntries(from: existingEntries, targetURL: targetURL, scriptPath: scriptPath)
            if generatedEntries.isEmpty {
                if stripped.kept.isEmpty { result.removeValue(forKey: key) }
                else { result[key] = stripped.kept }
            } else {
                result[key] = stripped.kept + generatedEntries
            }
        }
        return result
    }

    /// hooks 字典中是否存在 VibeFocus 条目（isHookInstalled 判定核心）
    static func containsVibeFocusHook(hooks: [String: Any], targetURL: String, scriptPath: String) -> Bool {
        for (_, entries) in hooks {
            guard let entryList = entries as? [[String: Any]] else { continue }
            for entry in entryList {
                guard let hookList = entry["hooks"] as? [[String: Any]] else { continue }
                if hookList.contains(where: { isVibeFocusHook($0, targetURL: targetURL, scriptPath: scriptPath) }) {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

let url = "http://127.0.0.1:39277/claude/hook"
let script = "/usr/local/bin/vf-helper.sh"

func ourEntry() -> [String: Any] {
    ["hooks": [["type": "command", "command": "\(script) session-start"]]]
}

func foreignEntry() -> [String: Any] {
    ["hooks": [["type": "command", "command": "/usr/bin/echo user-own-hook"]]]
}

// MARK: 1. isVibeFocusHook — 识别判据全分支

print("1. isVibeFocusHook")

check("url 精确相等 → 识别",
      MirrorHookSettingsComposition.isVibeFocusHook(["url": url], targetURL: url, scriptPath: script))
check("command 含脚本路径 → 识别",
      MirrorHookSettingsComposition.isVibeFocusHook(["command": "bash \(script) stop"], targetURL: url, scriptPath: script))
check("url 与 command 双命中 → 识别（OR 语义）",
      MirrorHookSettingsComposition.isVibeFocusHook(["url": url, "command": "\(script) x"], targetURL: url, scriptPath: script))
check("url 不同端口（旧配置换端口）+ command 无关 → 不识别（判据即历史行为，不含模糊匹配）",
      !MirrorHookSettingsComposition.isVibeFocusHook(["url": "http://127.0.0.1:1/claude/hook", "command": "echo hi"], targetURL: url, scriptPath: script))
check("两字段皆缺 → 不识别",
      !MirrorHookSettingsComposition.isVibeFocusHook(["type": "command"], targetURL: url, scriptPath: script))
check("command 相似但不含完整脚本路径 → 不识别",
      !MirrorHookSettingsComposition.isVibeFocusHook(["command": "/usr/local/bin/vf-helper"], targetURL: url, scriptPath: script))
check("空字典 → 不识别",
      !MirrorHookSettingsComposition.isVibeFocusHook([:], targetURL: url, scriptPath: script))

// MARK: 2. stripVibeFocusEntries — 移除与保留

print("\n2. stripVibeFocusEntries")

do {
    let r = MirrorHookSettingsComposition.stripVibeFocusEntries(from: [], targetURL: url, scriptPath: script)
    check("空输入 → 空输出", r.kept.isEmpty && r.removed == 0)
}
do {
    let r = MirrorHookSettingsComposition.stripVibeFocusEntries(from: [ourEntry(), foreignEntry()], targetURL: url, scriptPath: script)
    check("混合列表：只摘我们的，外部保留且次序不变", r.removed == 1 && r.kept.count == 1
          && (r.kept.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/usr/bin/echo user-own-hook")
}
do {
    let malformed: [String: Any] = ["matcher": "x"]  // 无 hooks 数组 → 外部条目
    let r = MirrorHookSettingsComposition.stripVibeFocusEntries(from: [malformed], targetURL: url, scriptPath: script)
    check("缺 hooks 数组的 entry 视为外部条目原样保留", r.removed == 0 && r.kept.count == 1)
}
do {
    let httpEntry: [String: Any] = ["hooks": [["type": "http", "url": url]]]
    let r = MirrorHookSettingsComposition.stripVibeFocusEntries(from: [httpEntry], targetURL: url, scriptPath: script)
    check("旧版 HTTP 型条目也被摘除（判据兼容旧格式）", r.removed == 1 && r.kept.isEmpty)
}

// MARK: 3. composeDesiredHooks — 终态编排（含 bug 修复锁定）

print("\n3. composeDesiredHooks")

func generated(events: [String]) -> [String: Any] {
    var g: [String: Any] = [:]
    for e in events { g[e] = [ourEntry()] }
    return g
}
let fullGenerated = generated(events: ["SessionStart", "Stop", "SessionEnd", "UserPromptSubmit"])
let noSessionEnd = generated(events: ["SessionStart", "Stop", "UserPromptSubmit"])  // triggerOnSessionEnd=false 形态

do {
    let r = MirrorHookSettingsComposition.composeDesiredHooks(existing: [:], generated: fullGenerated, targetURL: url, scriptPath: script)
    check("全新安装：生成 4 事件", r.keys.sorted() == ["SessionEnd", "SessionStart", "Stop", "UserPromptSubmit"])
}
do {
    let existing: [String: Any] = ["SessionStart": [ourEntry()]]
    let r = MirrorHookSettingsComposition.composeDesiredHooks(existing: existing, generated: fullGenerated, targetURL: url, scriptPath: script)
    let entries = r["SessionStart"] as? [[String: Any]] ?? []
    check("重装：旧条目被替换不叠加（幂等防重）", entries.count == 1)
}
do {
    let existing: [String: Any] = ["SessionStart": [ourEntry()]]
    let once = MirrorHookSettingsComposition.composeDesiredHooks(existing: existing, generated: fullGenerated, targetURL: url, scriptPath: script)
    let twice = MirrorHookSettingsComposition.composeDesiredHooks(existing: once, generated: fullGenerated, targetURL: url, scriptPath: script)
    let onceCount = (once["SessionStart"] as? [[String: Any]])?.count ?? -1
    let twiceCount = (twice["SessionStart"] as? [[String: Any]])?.count ?? -1
    check("重复安装幂等：compose(compose(x)) == compose(x)", onceCount == twiceCount)
}
do {
    let existing: [String: Any] = ["SessionStart": [foreignEntry()]]
    let r = MirrorHookSettingsComposition.composeDesiredHooks(existing: existing, generated: fullGenerated, targetURL: url, scriptPath: script)
    let entries = r["SessionStart"] as? [[String: Any]] ?? []
    check("外部 hook 与本 app 条目共存（旧实现整键覆盖会丢弃外部 hook——已修）",
          entries.count == 2 && (entries.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/usr/bin/echo user-own-hook")
}
do {
    // 第十七刀核心 bug 锁定：旧实现 removeValue 整键删除，用户自装 SessionEnd 一并被清
    let existing: [String: Any] = ["SessionEnd": [foreignEntry()]]
    let r = MirrorHookSettingsComposition.composeDesiredHooks(existing: existing, generated: noSessionEnd, targetURL: url, scriptPath: script)
    check("开关关闭 + 用户自装同事件 hook → 外部 hook 保留（整键删除 bug 已修）",
          r["SessionEnd"] != nil)
}
do {
    let existing: [String: Any] = ["SessionEnd": [ourEntry()]]
    let r = MirrorHookSettingsComposition.composeDesiredHooks(existing: existing, generated: noSessionEnd, targetURL: url, scriptPath: script)
    check("开关关闭 + 仅我们的旧 SessionEnd → 键整个移除", r["SessionEnd"] == nil)
}
do {
    let existing: [String: Any] = ["SessionEnd": [foreignEntry(), ourEntry()]]
    let r = MirrorHookSettingsComposition.composeDesiredHooks(existing: existing, generated: noSessionEnd, targetURL: url, scriptPath: script)
    let entries = r["SessionEnd"] as? [[String: Any]] ?? []
    check("开关关闭 + 外部与我们的混杂 → 仅摘我们的，键随外部条目保留", entries.count == 1)
}
do {
    let existing: [String: Any] = ["CustomEvent": [foreignEntry()]]
    let r = MirrorHookSettingsComposition.composeDesiredHooks(existing: existing, generated: fullGenerated, targetURL: url, scriptPath: script)
    check("生成集之外的外部事件键不受影响", r["CustomEvent"] != nil)
}
do {
    let existing: [String: Any] = ["Stop": ["notAnArray"]] as [String: Any]
    let r = MirrorHookSettingsComposition.composeDesiredHooks(existing: existing, generated: fullGenerated, targetURL: url, scriptPath: script)
    check("非数组形态的现有值在生成集覆盖时被替换为正规条目",
          (r["Stop"] as? [[String: Any]])?.count == 1)
}

// MARK: 4. containsVibeFocusHook — 安装状态判定

print("\n4. containsVibeFocusHook")

check("首事件命中 → true",
      MirrorHookSettingsComposition.containsVibeFocusHook(hooks: ["SessionStart": [ourEntry()]], targetURL: url, scriptPath: script))
check("深层第二 entry 命中 → true",
      MirrorHookSettingsComposition.containsVibeFocusHook(
        hooks: ["Stop": [foreignEntry(), ourEntry()]], targetURL: url, scriptPath: script))
check("全外部 → false",
      !MirrorHookSettingsComposition.containsVibeFocusHook(hooks: ["Stop": [foreignEntry()]], targetURL: url, scriptPath: script))
check("空 hooks → false",
      !MirrorHookSettingsComposition.containsVibeFocusHook(hooks: [:], targetURL: url, scriptPath: script))
check("事件值非数组 → 跳过不崩",
      !MirrorHookSettingsComposition.containsVibeFocusHook(hooks: ["Stop": "garbage"], targetURL: url, scriptPath: script))
check("entry 的 hooks 非数组 → 跳过不崩",
      !MirrorHookSettingsComposition.containsVibeFocusHook(
        hooks: ["Stop": [["hooks": "garbage"]]], targetURL: url, scriptPath: script))

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
