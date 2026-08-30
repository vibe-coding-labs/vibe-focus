// CodexHookInstaller.swift
// VibeFocus — Codex CLI Hook 安装/卸载逻辑
// Codex 的 hooks.json schema 与 Claude Code settings.json 的 hooks 字段同构
// （PascalCase 事件键名 + matcher/hooks/command 嵌套），故复用 generateHooksDict / makeHookEntry。
// 差异：Codex 配置在 ~/.codex/hooks.json 独立文件（config.toml 用 hooks = "./hooks.json" 引用），
// 且 Codex 有 hook trust 机制，首次运行需用户在 TUI 确认信任。

import Foundation

// MARK: - Codex Hook Installation

enum CodexHookPreferences {

    // MARK: - Paths

    static var codexConfigDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    static var codexConfigPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/hooks.json")
    }

    // MARK: - Installation State

    static var isHookInstalled: Bool {
        // P-INST-282: Codex hook 安装状态检查耗时（Data(contentsOf codexConfigPath) + JSONSerialization 解析 + hooks 字典遍历匹配 command 含 helperScriptPath；设置面板 Codex UI 状态渲染调用）。
        #if PERF_INSTRUMENT
        let ihiStart = Date()
        defer {
            log("CodexHookPreferences.isHookInstalled finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ihiStart))
            ])
        }
        #endif
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: codexConfigPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let scriptPath = ClaudeHookPreferences.helperScriptPath
        for (_, entries) in json {
            guard let entryList = entries as? [[String: Any]] else { continue }
            for entry in entryList {
                guard let hookList = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in hookList {
                    if let command = hook["command"] as? String, command.contains(scriptPath) {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Install / Uninstall

    /// 安装 VibeFocus hook 到 Codex ~/.codex/hooks.json
    /// 复用 ClaudeHookPreferences 的 helper script 安装、配置文件写入与 hooks 字典生成
    static func installHookToCodexSettings() -> (Bool, String) {
        // P-INST-283: Codex hooks.json 安装耗时（installHelperScript P-INST-88 + writeConfigFile P-INST-87 + 读/清理/合并/原子写 hooks.json；设置面板 Codex 安装按钮调用；与 installHookToClaudeSettings P-INST-78 对称）。
        #if PERF_INSTRUMENT
        let ihStart = Date()
        defer {
            log("[CodexHookPreferences] installHookToCodexSettings finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ihStart))
            ])
        }
        #endif
        // 确保已有 token（hook-config.json 需要）
        ClaudeHookPreferences.ensureTokenGenerated()

        let path = codexConfigPath
        let dir = codexConfigDir

        // 安装辅助脚本（与 Claude Code 共用 ~/.vibefocus/hook-forwarder.sh）
        let (scriptOK, scriptMsg) = ClaudeHookPreferences.installHelperScript()
        if !scriptOK {
            log("[CodexHookPreferences] helper script install failed: \(scriptMsg)", level: .error)
            return (false, scriptMsg)
        }

        // 写入配置文件（端口和 Token，与 Claude Code 共用 ~/.vibefocus/hook-config.json）
        ClaudeHookPreferences.writeConfigFile()

        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            log("[CodexHookPreferences] install failed: cannot create dir \(dir): \(error.localizedDescription)", level: .error)
            return (false, "无法创建目录: \(error.localizedDescription)")
        }

        // Codex hooks.json 是独立文件，顶层就是事件键名 → entry list 的映射
        // 读取现有内容（不存在则从空字典开始），保留用户其他 hook 条目
        var hooks: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            hooks = existing
            log("[CodexHookPreferences] read existing hooks.json, keys: \(hooks.keys.sorted().joined(separator: ","))")
        }

        // 清理旧的 VibeFocus hook 条目
        cleanVibeFocusHooks(from: &hooks)

        // 合并新生成的 hook 条目
        let ourHooks = ClaudeHookPreferences.generateHooksDict()
        for (key, value) in ourHooks {
            hooks[key] = value
        }
        // 与 Claude Code 安装逻辑保持一致：根据触发开关移除不需要的事件
        if !ClaudeHookPreferences.triggerOnSessionEnd { hooks.removeValue(forKey: "SessionEnd") }
        if !ClaudeHookPreferences.autoRestoreOnPromptSubmit { hooks.removeValue(forKey: "UserPromptSubmit") }

        log(
            "[CodexHookPreferences] installing hooks",
            fields: [
                "path": path,
                "hookEvents": hooks.keys.sorted().joined(separator: ","),
                "helperScript": ClaudeHookPreferences.helperScriptPath
            ]
        )

        guard let data = try? JSONSerialization.data(withJSONObject: hooks, options: [.prettyPrinted, .sortedKeys]) else {
            return (false, "无法序列化 JSON")
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            log("[CodexHookPreferences] hooks installed successfully to \(path)")
            return (true, "已安装到 Codex（\(path)）")
        } catch {
            log("[CodexHookPreferences] install write failed: \(error.localizedDescription)", level: .error)
            return (false, "写入失败: \(error.localizedDescription)")
        }
    }

    /// 从 Codex ~/.codex/hooks.json 移除 VibeFocus hook
    static func uninstallHookFromCodexSettings() -> (Bool, String) {
        // P-INST-284: Codex hook 卸载耗时（Data(contentsOf codexConfigPath) 读 + JSONSerialization 解析 + cleanVibeFocusHooks 清理 + JSONSerialization 编码 + atomic write；设置面板 Codex 卸载按钮调用）。
        #if PERF_INSTRUMENT
        let uhStart = Date()
        defer {
            log("[CodexHookPreferences] uninstallHookFromCodexSettings finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: uhStart))
            ])
        }
        #endif
        let path = codexConfigPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var hooks = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 文件不存在视为已卸载
            return (true, "Codex 配置不存在，无需卸载")
        }

        cleanVibeFocusHooks(from: &hooks)

        log("[CodexHookPreferences] uninstalling hooks from \(path)", fields: ["remainingEvents": hooks.keys.sorted().joined(separator: ",")])

        guard let outputData = try? JSONSerialization.data(withJSONObject: hooks, options: [.prettyPrinted, .sortedKeys]) else {
            return (false, "无法序列化配置")
        }
        do {
            try outputData.write(to: URL(fileURLWithPath: path), options: .atomic)
            log("[CodexHookPreferences] hooks uninstalled successfully from Codex")
            return (true, "已从 Codex 移除 Hook")
        } catch {
            log("[CodexHookPreferences] uninstall write failed: \(error.localizedDescription)", level: .error)
            return (false, "写入失败: \(error.localizedDescription)")
        }
    }

    /// 从 hooks 字典中清理所有 VibeFocus 相关的 hook 条目
    /// 逻辑与 ClaudeHookPreferences.cleanVibeFocusHooks 一致（Codex hooks.json 顶层即事件键名）
    private static func cleanVibeFocusHooks(from hooks: inout [String: Any]) {
        log("[CodexHookPreferences] cleanVibeFocusHooks() entered", level: .debug, fields: [
            "keysBefore": hooks.keys.sorted().joined(separator: ",")
        ])
        let scriptPath = ClaudeHookPreferences.helperScriptPath
        for key in ["SessionStart", "Stop", "SessionEnd", "UserPromptSubmit"] {
            guard var entries = hooks[key] as? [[String: Any]] else { continue }
            let countBefore = entries.count
            entries.removeAll { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { hook in
                    if let command = hook["command"] as? String, command.contains(scriptPath) { return true }
                    return false
                }
            }
            if entries.isEmpty { hooks.removeValue(forKey: key) }
            else { hooks[key] = entries }
            log("[CodexHookPreferences] cleanVibeFocusHooks() cleaned \(key)", level: .debug, fields: [
                "removed": String(countBefore - entries.count)
            ])
        }
    }
}
