// HookInstaller.swift
// VibeFocus — Hook 安装/卸载逻辑
// 从 ClaudeHookPreferences.swift 中提取，职责：写入配置、安装脚本、注册/清理 hooks

import Foundation

// MARK: - Hook Installation

extension ClaudeHookPreferences {

    // MARK: - Config & Helper Script

    /// 写入辅助脚本配置文件（端口和 Token）
    /// hook-config.json 内容组装（纯函数，B143 提纯）：port/token 恒在；
    /// lanMode 时附 host=本机活跃 LAN IP（远程转发器指向依据）。
    static func makeConfigData(port: Int, token: String, host: String?) -> Data? {
        var config: [String: Any] = [
            "port": port,
            "token": token
        ]
        if let host { config["host"] = host }
        return try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    /// home 注入变体（B253）：默认真身路径（生产零变更），测试传临时 home。
    static func writeConfigFile(home: String = NSHomeDirectory()) {
        // P-INST-87: hook 辅助脚本配置写入耗时（createDirectory + JSONSerialization.data + data.write(.atomic) 写 hook-config.json；applyPreferences P-INST-77 / installHookToClaudeSettings P-INST-78 子阶段；token/port 同步）。
        #if PERF_INSTRUMENT
        let wcStart = Date()
        defer {
            log("ClaudeHookPreferences.writeConfigFile() finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: wcStart))
            ])
        }
        #endif
        log("ClaudeHookPreferences.writeConfigFile() entered", level: .debug, fields: [
            "dir": helperScriptDir,
            "path": configFilePath
        ])
        let dir = (home as NSString).appendingPathComponent(".vibefocus")
        let configPath = (dir as NSString).appendingPathComponent("hook-config.json")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // B170: 本机配置不再写 host——本机脚本恒直连 127.0.0.1（服务端 bind 0.0.0.0），
        // 不随 LAN IP 漂移失效；LAN IP 只属于远程机配置（远程安装脚本/复制配置通道）。
        let config: [String: Any] = [
            "port": listenPort,
            "token": authToken ?? ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else {
            log("ClaudeHookPreferences.writeConfigFile() failed to serialize config", level: .debug)
            return
        }
        try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        // 凭证权限收紧（2026-09-26 安全批）：token 落盘文件 0600——装机默认 644，
        // 本机任何其他用户/进程可读即等同交出窗口控制权。每次写都顺手收紧（幂等）。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
        log("ClaudeHookPreferences.writeConfigFile() completed", level: .debug, fields: ["lanMode": String(LANHookPreferences.lanMode), "configPath": configPath])
    }

    /// 安装辅助脚本到 ~/.vibefocus/hook-forwarder.sh
    @discardableResult
    static func installHelperScript(home: String = NSHomeDirectory()) -> (Bool, String) {
        // P-INST-88: 辅助脚本安装耗时（createDirectory + data.write(.atomic) 写 hook-forwarder.sh + setAttributes posixPermissions 0o755；applyPreferences P-INST-77 / installHookToClaudeSettings P-INST-78 子阶段；memory feedback_hook_forwarder_verification 关注的脚本写入正确性路径）。
        #if PERF_INSTRUMENT
        let ihsStart = Date()
        defer {
            log("ClaudeHookPreferences.installHelperScript() finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ihsStart))
            ])
        }
        #endif
        log("ClaudeHookPreferences.installHelperScript() entered", level: .debug)
        return installHelperScript(
            content: generateHelperScriptContent(),
            to: (home as NSString).appendingPathComponent(".vibefocus/hook-forwarder.sh"))
    }

    /// 路径注入变体（B144）：测试以临时文件直测安装语义（0755/原子写/幂等覆盖），
    /// 不触真身脚本。dir 创建失败如实报错。
    static func installHelperScript(content: String, to path: String) -> (Bool, String) {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return (false, "无法创建目录: \(error.localizedDescription)")
        }
        guard let data = content.data(using: .utf8) else {
            return (false, "无法生成辅助脚本")
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            log("[ClaudeHookPreferences] helper script installed to \(path)")
            return (true, "辅助脚本已安装")
        } catch {
            return (false, "安装辅助脚本失败: \(error.localizedDescription)")
        }
    }

    /// 移除辅助脚本和配置文件
    /// home 注入变体（B253 续）：默认真身路径（生产零变更），测试传临时 home。
    static func removeHelperFiles(home: String = NSHomeDirectory()) {
        // P-INST-89: 辅助脚本与配置清理耗时（2x removeItem hook-forwarder.sh + hook-config.json；uninstallHookFromClaudeSettings P-INST-83 子阶段；卸载/重装时调用）。
        #if PERF_INSTRUMENT
        let rhStart = Date()
        defer {
            log("ClaudeHookPreferences.removeHelperFiles() finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: rhStart))
            ])
        }
        #endif
        log("ClaudeHookPreferences.removeHelperFiles() entered", level: .debug, fields: [
            "scriptPath": helperScriptPath,
            "configPath": configFilePath
        ])
        let scriptPath = (home as NSString).appendingPathComponent(".vibefocus/hook-forwarder.sh")
        let configPath = (home as NSString).appendingPathComponent(".vibefocus/hook-config.json")
        try? FileManager.default.removeItem(atPath: scriptPath)
        try? FileManager.default.removeItem(atPath: configPath)
        log("[ClaudeHookPreferences] helper files removed", fields: [
            "scriptPath": scriptPath, "configPath": configPath
        ])
    }

    // MARK: - Settings.json Integration

    /// 安全 merge Hook 到 Claude settings.json
    /// 只覆盖 SessionStart/Stop/SessionEnd/UserPromptSubmit 四个 key，保留用户其他 hooks 和配置
    ///
    /// ## 场景
    /// - 触发时机：AppDelegate 启动、hook 偏好变更（applyPreferences）、设置页手动安装
    /// - 冷却语义：3s 冷却只拦截"期望内容与磁盘一致"的无变化重装；内容有变化
    ///   （如刚关闭 triggerOnSessionEnd 需要摘除 SessionEnd hook）必须落盘——
    ///   否则开关切换后 3s 内的同步被吞，settings.json 残留已禁用的 hook 而 UI
    ///   显示成功（曾发生的静默不一致 bug）。
    /// home 注入变体（B253 续）：默认真身路径（生产零变更），测试传临时 home。
    static func installHookToClaudeSettings(home: String = NSHomeDirectory()) -> (Bool, String) {
        // P-INST-78: claude settings 安装耗时（读 settings.json + JSONSerialization 解析 + cleanVibeFocusHooks + 编码 + atomic 写；含 3s 冷却防抖跳过；memory feedback_hook_forwarder_verification 关注的配置正确性路径；applyPreferences P-INST-77 子阶段）。
        #if PERF_INSTRUMENT
        let ihStart = Date()
        defer {
            log("[ClaudeHookPreferences] installHookToClaudeSettings finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ihStart))
            ])
        }
        #endif
        ensureTokenGenerated()
        let path = claudeSettingsPath(home: home)
        let dir = claudeSettingsDir(home: home)

        // 安装辅助脚本
        let (scriptOK, scriptMsg) = installHelperScript(home: home)
        if !scriptOK {
            log("[ClaudeHookPreferences] helper script install failed: \(scriptMsg)", level: .error)
            return (false, scriptMsg)
        }

        // 写入配置文件（端口和 Token）
        writeConfigFile(home: home)

        let lastInstall = UserDefaults.standard.object(forKey: lastInstallAtKey) as? Date ?? .distantPast
        return installHooks(
            at: path,
            dir: dir,
            scriptPath: (home as NSString).appendingPathComponent(".vibefocus/hook-forwarder.sh"),
            targetURL: endpointURLString(),
            // B253：generated 的 command 内嵌 scriptPath——识别键与内容必须同源，
            // 否则二次安装把首装条目误判为外部 hook 而追加重复。
            generated: generateHooksDict(
                scriptPath: (home as NSString).appendingPathComponent(".vibefocus/hook-forwarder.sh")),
            now: Date(),
            lastInstall: lastInstall,
            recordInstall: { UserDefaults.standard.set($0, forKey: lastInstallAtKey) }
        )
    }

    // MARK: - B201 项目级安装（<projectDir>/.claude/settings.json）

    static func projectClaudeSettingsPath(projectDir: String) -> String {
        (projectDir as NSString).appendingPathComponent(".claude/settings.json")
    }

    static func projectClaudeSettingsDir(projectDir: String) -> String {
        (projectDir as NSString).appendingPathComponent(".claude")
    }

    /// 项目级一键安装：只写 <projectDir>/.claude/settings.json（团队仓库/按项目
    /// 选择性启用），不触碰全局 settings.json，不落 token/脚本到项目目录——
    /// 转发器读全局 ~/.vibefocus/hook-config.json（token 单一来源，不进 git）。
    /// 无 3s 冷却（CLI 一次性动作，非 UI 高频路径）。
    @discardableResult
    static func installHookToProject(_ projectDir: String) -> (Bool, String) {
        ensureTokenGenerated()
        return installHooks(
            at: projectClaudeSettingsPath(projectDir: projectDir),
            dir: projectClaudeSettingsDir(projectDir: projectDir),
            scriptPath: helperScriptPath,
            targetURL: endpointURLString(),
            generated: generateHooksDict()
        )
    }

    /// 项目级卸载：摘除我方条目、保留外部 hook；绝不删全局共享的辅助脚本
    ///（removesHelpers=false——脚本归全局安装所有，项目卸载无权清理）。
    @discardableResult
    static func uninstallHookFromProject(_ projectDir: String) -> (Bool, String) {
        uninstallHookFromClaudeSettings(
            at: projectClaudeSettingsPath(projectDir: projectDir),
            removesHelpers: false
        )
    }

    /// 安装编排核心（B155 注入缝，与卸载侧 B33 对称）：建目录→读盘→composeDesiredHooks
    /// 合并（2.16a 第十七刀）→3s 冷却→原子写。真实辅助脚本安装、hook-config 写入与
    /// UserDefaults 时间戳留在生产壳；测试注入 temp 目录穷举合并/冷却/落盘语义。
    static func installHooks(
        at path: String,
        dir: String,
        scriptPath: String,
        targetURL: String,
        generated: [String: Any],
        now: Date = Date(),
        lastInstall: Date = .distantPast,
        recordInstall: (Date) -> Void = { _ in }
    ) -> (Bool, String) {
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

        let existingHooks = (settings["hooks"] as? [String: Any]) ?? [:]
        // 期望终态编排（2.16a 第十七刀）：识别判据与合并顺序收敛到 HookSettingsComposition
        // 纯函数；外部 hook 一律保留（旧实现开关关闭时 removeValue 整键删除，连带清掉
        // 用户自装的同事件 hook——真 bug，随本刀修复）。
        let desiredHooks = HookSettingsComposition.composeDesiredHooks(
            existing: existingHooks,
            generated: generated,
            targetURL: targetURL,
            scriptPath: scriptPath
        )
        settings["hooks"] = desiredHooks

        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else {
            return (false, "无法序列化 JSON")
        }

        // 冷却判定放在内容计算之后：只有期望内容与磁盘字节一致（真正的无变化重装）
        // 才允许跳过；lastInstallAt 也只在真实落盘时更新
        if now.timeIntervalSince(lastInstall) < installCooldown,
           let existingData = try? Data(contentsOf: URL(fileURLWithPath: path)),
           existingData == data {
            log("[ClaudeHookPreferences] install skipped: cooldown active, content unchanged")
            return (true, "配置无变化")
        }

        log(
            "[ClaudeHookPreferences] installing hooks",
            fields: [
                "path": path,
                "hookEvents": desiredHooks.keys.sorted().joined(separator: ","),
                "totalSettingsKeys": String(settings.count),
                "helperScript": scriptPath
            ]
        )

        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            recordInstall(now)
            log("[ClaudeHookPreferences] hooks installed successfully to \(path)")
            return (true, "已安装到 \(path)")
        } catch {
            log("[ClaudeHookPreferences] install write failed: \(error.localizedDescription)", level: .error)
            return (false, "写入失败: \(error.localizedDescription)")
        }
    }

    /// 从 Claude settings.json 中精确移除 VibeFocus Hook
    /// 依赖注入点（B33）：`at`/`scriptPath`/`targetURL` 缺省生产值；`removesHelpers=false`
    /// 供测试跳过真身辅助文件清理。
    static func uninstallHookFromClaudeSettings(
        at path: String = claudeSettingsPath(),
        scriptPath: String = ClaudeHookPreferences.helperScriptPath,
        targetURL: String = ClaudeHookPreferences.endpointURLString(),
        removesHelpers: Bool = true
    ) -> (Bool, String) {
        // P-INST-83: hook 卸载耗时（Data(contentsOf claudeSettingsPath) 读 + JSONSerialization 解析 + cleanVibeFocusHooks 遍历清理 + JSONSerialization 编码 + atomic write + removeHelperFiles 两次 removeItem；设置面板卸载按钮触发；P-INST-78 install 的逆操作）。
        #if PERF_INSTRUMENT
        let uhStart = Date()
        defer {
            log("[ClaudeHookPreferences] uninstallHookFromClaudeSettings finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: uhStart))
            ])
        }
        #endif
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else {
            return (false, "无法读取 Claude 配置")
        }

        // 卸载 = 期望终态为空生成集的编排（与 install 共用同一判据，2.16a 第十七刀）
        let desiredHooks = HookSettingsComposition.composeDesiredHooks(
            existing: hooks,
            generated: [:],
            targetURL: targetURL,
            scriptPath: scriptPath
        )
        settings["hooks"] = desiredHooks.isEmpty ? nil : desiredHooks

        log("[ClaudeHookPreferences] uninstalling hooks from \(path)", fields: ["remainingEvents": hooks.keys.sorted().joined(separator: ",")])

        guard let outputData = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else {
            return (false, "无法序列化配置")
        }
        do {
            try outputData.write(to: URL(fileURLWithPath: path), options: .atomic)
            // 清理辅助文件（测试注入 removesHelpers=false 跳过真身删除）
            if removesHelpers { removeHelperFiles() }
            log("[ClaudeHookPreferences] hooks uninstalled successfully")
            return (true, "已移除 Hook")
        } catch {
            log("[ClaudeHookPreferences] uninstall write failed: \(error.localizedDescription)", level: .error)
            return (false, "写入失败: \(error.localizedDescription)")
        }
    }
}

/// B201 项目级安装的公开 CLI 门面——AppEntry 目标只见 public 符号，
/// 实现留在 ClaudeHookPreferences（internal，Runner 真身直测）。
public enum ProjectHookInstaller {
    /// `--install-claude-hook-project <dir>`：只写 <dir>/.claude/settings.json。
    @discardableResult
    public static func install(_ projectDir: String) -> (Bool, String) {
        ClaudeHookPreferences.installHookToProject(projectDir)
    }

    /// `--uninstall-claude-hook-project <dir>`：摘我方条目保外部，不删全局脚本。
    @discardableResult
    public static func uninstall(_ projectDir: String) -> (Bool, String) {
        ClaudeHookPreferences.uninstallHookFromProject(projectDir)
    }
}
