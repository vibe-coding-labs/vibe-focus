// HookSettingsComposition.swift
// VibeFocus — Claude settings.json hooks 字段编排纯函数（2.16a 第十七刀）
// 收敛三处各自内联的"VibeFocus hook 条目识别"判据（install 清理 / isHookInstalled /
// 卸载）与 install 的顺序依赖变异编排。终态语义：只动 VibeFocus 自己的条目，
// 用户自装的外部 hook 一律保留。
// 消费者：HookInstaller.installHookToClaudeSettings / uninstallHookFromClaudeSettings、
//         ClaudeHookPreferences.isHookInstalled。
// 测试：Tests/Standalone/HookSettingsCompositionTests.swift（分支穷尽 + bug 修复锁定）。

import Foundation

/// Claude settings.json hooks 字段的纯函数编排（无 I/O，输入输出皆为值）。
enum HookSettingsComposition {

    /// VibeFocus hook 条目识别唯一判据：url 精确相等 OR command 含辅助脚本路径。
    /// 判据即历史行为（含"换端口后旧 HTTP 条目不识别"的已知局限——判据变更
    /// 影响用户文件删除范围，须真实环境验证后另行走刀）。
    static func isVibeFocusHook(_ hook: [String: Any], targetURL: String, scriptPath: String) -> Bool {
        if let url = hook["url"] as? String, url == targetURL { return true }
        if let command = hook["command"] as? String, command.contains(scriptPath) { return true }
        return false
    }

    /// 单事件 entry 数组移除 VibeFocus 条目。entry 无 "hooks" 数组视为外部条目，原样保留。
    static func stripVibeFocusEntries(
        from entries: [[String: Any]],
        targetURL: String,
        scriptPath: String
    ) -> (kept: [[String: Any]], removed: Int) {
        var removed = 0
        let kept = entries.filter { entry in
            guard let hookList = entry["hooks"] as? [[String: Any]] else { return true }
            let isOurs = hookList.contains { isVibeFocusHook($0, targetURL: targetURL, scriptPath: scriptPath) }
            if isOurs { removed += 1 }
            return !isOurs
        }
        return (kept, removed)
    }

    /// 期望 hooks 终态：现有键 ∪ 生成键全扫描，摘除全部 VibeFocus 旧条目后并入 generated。
    /// - generated 声明的事件：外部条目与新生成条目共存（旧实现整键覆盖丢弃外部 hook，已修）；
    /// - generated 不声明的事件（开关关闭）：仅摘我们的旧条目，键随外部条目去留
    ///   （旧实现 removeValue 整键删除连带清掉用户自装的同事件 hook，已修）。
    static func composeDesiredHooks(
        existing: [String: Any],
        generated: [String: Any],
        targetURL: String,
        scriptPath: String
    ) -> [String: Any] {
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

    /// hooks 字典中是否存在 VibeFocus 条目（isHookInstalled 判定核心）。
    /// 畸形结构（事件值/entry 的 hooks 非数组）跳过不崩，与历史遍历行为一致。
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
