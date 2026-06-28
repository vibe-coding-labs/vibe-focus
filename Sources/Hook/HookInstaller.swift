// HookInstaller.swift
// VibeFocus — Hook 安装/卸载逻辑
// 从 ClaudeHookPreferences.swift 中提取，职责：写入配置、安装脚本、注册/清理 hooks

import Foundation

// MARK: - Hook Installation

extension ClaudeHookPreferences {

    // MARK: - Config & Helper Script

    /// 写入辅助脚本配置文件（端口和 Token）
    static func writeConfigFile() {
        // P-INST-87: hook 辅助脚本配置写入耗时（createDirectory + JSONSerialization.data + data.write(.atomic) 写 hook-config.json；applyPreferences P-INST-77 / installHookToClaudeSettings P-INST-78 子阶段；token/port 同步）。
        let wcStart = Date()
        defer {
            log("ClaudeHookPreferences.writeConfigFile() finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: wcStart))
            ])
        }
        log("ClaudeHookPreferences.writeConfigFile() entered", level: .debug, fields: [
            "dir": helperScriptDir,
            "path": configFilePath
        ])
        let dir = helperScriptDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var config: [String: Any] = [
            "port": listenPort,
            "token": authToken ?? ""
        ]
        if LANHookPreferences.lanMode {
            config["host"] = LANHookPreferences.currentLANIP()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else {
            log("ClaudeHookPreferences.writeConfigFile() failed to serialize config", level: .debug)
            return
        }
        try? data.write(to: URL(fileURLWithPath: configFilePath), options: .atomic)
        log("ClaudeHookPreferences.writeConfigFile() completed", level: .debug, fields: ["lanMode": String(LANHookPreferences.lanMode)])
    }

    /// 安装辅助脚本到 ~/.vibefocus/hook-forwarder.sh
    @discardableResult
    static func installHelperScript() -> (Bool, String) {
        // P-INST-88: 辅助脚本安装耗时（createDirectory + data.write(.atomic) 写 hook-forwarder.sh + setAttributes posixPermissions 0o755；applyPreferences P-INST-77 / installHookToClaudeSettings P-INST-78 子阶段；memory feedback_hook_forwarder_verification 关注的脚本写入正确性路径）。
        let ihsStart = Date()
        defer {
            log("ClaudeHookPreferences.installHelperScript() finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ihsStart))
            ])
        }
        log("ClaudeHookPreferences.installHelperScript() entered", level: .debug)
        let dir = helperScriptDir
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            log("ClaudeHookPreferences.installHelperScript() failed to create dir", level: .debug, fields: ["error": error.localizedDescription])
            return (false, "无法创建目录: \(error.localizedDescription)")
        }

        let content = generateHelperScriptContent()
        guard let data = content.data(using: .utf8) else {
            log("ClaudeHookPreferences.installHelperScript() failed to encode script", level: .debug)
            return (false, "无法生成辅助脚本")
        }
        do {
            try data.write(to: URL(fileURLWithPath: helperScriptPath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperScriptPath)
            log("[ClaudeHookPreferences] helper script installed to \(helperScriptPath)")
            return (true, "辅助脚本已安装")
        } catch {
            log("ClaudeHookPreferences.installHelperScript() write failed", level: .debug, fields: ["error": error.localizedDescription])
            return (false, "安装辅助脚本失败: \(error.localizedDescription)")
        }
    }

    /// 移除辅助脚本和配置文件
    static func removeHelperFiles() {
        // P-INST-89: 辅助脚本与配置清理耗时（2x removeItem hook-forwarder.sh + hook-config.json；uninstallHookFromClaudeSettings P-INST-83 子阶段；卸载/重装时调用）。
        let rhStart = Date()
        defer {
            log("ClaudeHookPreferences.removeHelperFiles() finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: rhStart))
            ])
        }
        log("ClaudeHookPreferences.removeHelperFiles() entered", level: .debug, fields: [
            "scriptPath": helperScriptPath,
            "configPath": configFilePath
        ])
        try? FileManager.default.removeItem(atPath: helperScriptPath)
        try? FileManager.default.removeItem(atPath: configFilePath)
        log("[ClaudeHookPreferences] helper files removed")
    }

    // MARK: - Settings.json Integration

    /// 安全 merge Hook 到 Claude settings.json
    /// 只覆盖 SessionStart/Stop/SessionEnd/UserPromptSubmit 四个 key，保留用户其他 hooks 和配置
    static func installHookToClaudeSettings() -> (Bool, String) {
        // P-INST-78: claude settings 安装耗时（读 settings.json + JSONSerialization 解析 + cleanVibeFocusHooks + 编码 + atomic 写；含 3s 冷却防抖跳过；memory feedback_hook_forwarder_verification 关注的配置正确性路径；applyPreferences P-INST-77 子阶段）。
        let ihStart = Date()
        defer {
            log("[ClaudeHookPreferences] installHookToClaudeSettings finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ihStart))
            ])
        }
        // 防止 3 秒内重复调用
        let now = Date()
        let lastInstall = UserDefaults.standard.object(forKey: lastInstallAtKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(lastInstall) >= installCooldown else {
            log("[ClaudeHookPreferences] install skipped: cooldown active")
            return (true, "安装冷却中，请稍候")
        }
        UserDefaults.standard.set(now, forKey: lastInstallAtKey)

        ensureTokenGenerated()
        let path = claudeSettingsPath
        let dir = claudeSettingsDir

        // 安装辅助脚本
        let (scriptOK, scriptMsg) = installHelperScript()
        if !scriptOK {
            log("[ClaudeHookPreferences] helper script install failed: \(scriptMsg)", level: .error)
            return (false, scriptMsg)
        }

        // 写入配置文件（端口和 Token）
        writeConfigFile()

        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            log("[ClaudeHookPreferences] install failed: cannot create dir \(dir): \(error.localizedDescription)", level: .error)
            return (false, "无法创建目录: \(error.localizedDescription)")
        }

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
            log("[ClaudeHookPreferences] read existing settings, keys: \(settings.keys.sorted().joined(separator: ","))")
        }

        var existingHooks = (settings["hooks"] as? [String: Any]) ?? [:]
        // 先清理旧的 VibeFocus hooks（HTTP 和 command 类型）
        cleanVibeFocusHooks(from: &existingHooks)
        let ourHooks = generateHooksDict()
        for (key, value) in ourHooks {
            existingHooks[key] = value
        }
        // Stop 不再根据 triggerOnStop 移除 — handleStop 内部区分本地/远程
        if !triggerOnSessionEnd { existingHooks.removeValue(forKey: "SessionEnd") }
        if !autoRestoreOnPromptSubmit { existingHooks.removeValue(forKey: "UserPromptSubmit") }
        settings["hooks"] = existingHooks

        log(
            "[ClaudeHookPreferences] installing hooks",
            fields: [
                "path": path,
                "hookEvents": existingHooks.keys.sorted().joined(separator: ","),
                "totalSettingsKeys": String(settings.count),
                "helperScript": helperScriptPath
            ]
        )

        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else {
            return (false, "无法序列化 JSON")
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            log("[ClaudeHookPreferences] hooks installed successfully to \(path)")
            return (true, "已安装到 \(path)")
        } catch {
            log("[ClaudeHookPreferences] install write failed: \(error.localizedDescription)", level: .error)
            return (false, "写入失败: \(error.localizedDescription)")
        }
    }

    /// 从 hooks 字典中清理所有 VibeFocus 相关的 hook 条目（HTTP 和 command 类型）
    private static func cleanVibeFocusHooks(from hooks: inout [String: Any]) {
        log("ClaudeHookPreferences.cleanVibeFocusHooks() entered", level: .debug, fields: [
            "keysBefore": hooks.keys.sorted().joined(separator: ",")
        ])
        let targetURL = endpointURLString()
        let scriptPath = helperScriptPath
        for key in ["SessionStart", "Stop", "SessionEnd", "UserPromptSubmit"] {
            guard var entries = hooks[key] as? [[String: Any]] else { continue }
            let countBefore = entries.count
            entries.removeAll { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { hook in
                    if let url = hook["url"] as? String, url == targetURL { return true }
                    if let command = hook["command"] as? String, command.contains(scriptPath) { return true }
                    return false
                }
            }
            if entries.isEmpty { hooks.removeValue(forKey: key) }
            else { hooks[key] = entries }
            log("ClaudeHookPreferences.cleanVibeFocusHooks() cleaned \(key)", level: .debug, fields: [
                "removed": String(countBefore - entries.count)
            ])
        }
    }

    /// 从 Claude settings.json 中精确移除 VibeFocus Hook
    static func uninstallHookFromClaudeSettings() -> (Bool, String) {
        // P-INST-83: hook 卸载耗时（Data(contentsOf claudeSettingsPath) 读 + JSONSerialization 解析 + cleanVibeFocusHooks 遍历清理 + JSONSerialization 编码 + atomic write + removeHelperFiles 两次 removeItem；设置面板卸载按钮触发；P-INST-78 install 的逆操作）。
        let uhStart = Date()
        defer {
            log("[ClaudeHookPreferences] uninstallHookFromClaudeSettings finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: uhStart))
            ])
        }
        let path = claudeSettingsPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else {
            return (false, "无法读取 Claude 配置")
        }

        cleanVibeFocusHooks(from: &hooks)
        settings["hooks"] = hooks.isEmpty ? nil : hooks

        log("[ClaudeHookPreferences] uninstalling hooks from \(path)", fields: ["remainingEvents": hooks.keys.sorted().joined(separator: ",")])

        guard let outputData = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else {
            return (false, "无法序列化配置")
        }
        do {
            try outputData.write(to: URL(fileURLWithPath: path), options: .atomic)
            // 清理辅助文件
            removeHelperFiles()
            log("[ClaudeHookPreferences] hooks uninstalled successfully")
            return (true, "已移除 Hook")
        } catch {
            log("[ClaudeHookPreferences] uninstall write failed: \(error.localizedDescription)", level: .error)
            return (false, "写入失败: \(error.localizedDescription)")
        }
    }
}
