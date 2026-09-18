// CodexHookInstaller.swift
// VibeFocus — Codex CLI Hook 安装/卸载逻辑
// Codex hooks.json 文件形状（codex-cli 0.153.4 真机实证）：顶层只接受 description /
// hooks 字段，事件字典必须包在顶层 "hooks" 下；事件键 PascalCase。
// B207 事件集勘误与扩容（codex-cli 0.146.0 本机沙盒 mock 模型实证 + 官方 hooks 文档）：
// 此前「codex 没有 Stop/UserPromptSubmit」的断言过时——codex 现完整支持与 Claude
// 同名的 Stop（payload 带 last_assistant_message/stop_hook_active）与
// UserPromptSubmit（带 prompt），且事件 payload 与 Claude 逐字段同构
// （session_id/transcript_path/cwd/hook_event_name/model），同一解码器直接消费。
// 故注册：SessionStart 恒装（绑定自愈）+ Stop 恒装（服务端按 triggerOnStop
// remoteOnly 门控：拉主屏+完成语音播报+live 面板 done）+ UserPromptSubmit 按
// 「提交后自动归位」开关（绑定+归位+live 面板 running+环境上下文注入）+
// PermissionRequest 恒装（B206：等用户批准 → 通知中心，服务端按「等待输入通知」
// 开关门控）+ SessionEnd 按开关（codex 对 SessionEnd hook 超时钳 3s 上限，条目
// 直接写 3 免每次启动 clamp 警告）。旧版 codex 无这些事件时写入不触发、无副作用。
// 文件统一写规范形状；历史版本曾写顶层事件键（codex 解析失败、hooks 整体不加载），
// 读取/清理双形状兼容以迁移。Codex 有 hook trust 机制：按 hooks 当前内容 hash 记忆
// 信任，安装/变更后需用户在 TUI（/hooks）确认（自动化场景可用
// --dangerously-bypass-hook-trust），未信任的 hooks 被静默跳过。

import Foundation

// MARK: - Codex Hook Installation

enum CodexHookPreferences {

    // MARK: - Paths

    /// 依赖注入点（B32）：`home` 缺省生产家目录，测试注入临时目录即整链无真身 IO。
    static func codexConfigDir(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".codex")
    }

    static func codexConfigPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".codex/hooks.json")
    }

    // MARK: - Installation State

    static func isHookInstalled(at path: String = codexConfigPath()) -> Bool {
        // P-INST-282: Codex hook 安装状态检查耗时（Data(contentsOf codexConfigPath) + JSONSerialization 解析 + hooks 字典遍历匹配 command 含 helperScriptPath；设置面板 Codex UI 状态渲染调用）。
        #if PERF_INSTRUMENT
        let ihiStart = Date()
        defer {
            log("CodexHookPreferences.isHookInstalled finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ihiStart))
            ])
        }
        #endif
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let scriptPath = ClaudeHookPreferences.helperScriptPath
        for layer in codexHookLayers(in: document) {
            if layerContainsVibeFocusHooks(layer, scriptPath: scriptPath) {
                return true
            }
        }
        return false
    }

    /// codex 文档的事件字典层（双形状兼容，规范层在前）：0.153.4 规范形状 = 事件键
    /// 包在顶层 "hooks" 字段下；历史安装器曾把事件键写文档顶层（codex 解析失败、
    /// hooks 整体不加载）——两层都参与安装识别与卸载清理，旧坏文件可被迁移。
    static func codexHookLayers(in document: [String: Any]) -> [[String: Any]] {
        var layers: [[String: Any]] = []
        if let wrapped = document["hooks"] as? [String: Any] {
            layers.append(wrapped)
        }
        layers.append(document)
        return layers
    }

    private static func layerContainsVibeFocusHooks(_ hooks: [String: Any], scriptPath: String) -> Bool {
        for (_, entries) in hooks {
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

    /// Codex 可触发事件字典（B207 起：本地与远程 generateCodexHooksDictJSON 的唯一
    /// 事实源——远程生成器直接序列化本字典，消除两处手抄漂移面）：
    /// SessionStart 恒注册（远程 label 绑定自愈入口）+ Stop 恒注册（服务端
    /// handleStop 按 triggerOnStop remoteOnly 门控，与 Claude 同语义：拉主屏+
    /// 完成语音播报+live 面板 done）+ UserPromptSubmit 按「提交后自动归位」开关
    /// （绑定+归位+live 面板 running+additionalContext 注入）+ PermissionRequest
    /// 恒注册（B206：codex 弹权限确认停下等用户批准 → 通知中心 + live 面板
    /// waiting，与 Claude Notification 同管线，服务端按同一「等待输入通知」开关
    /// 门控——装进 hooks.json 但开关即时生效，无需重装）+ SessionEnd 按触发开关
    /// （条目超时写 3：codex 对 SessionEnd 钳 3s 上限，写 10 每次启动弹 clamp 警告）。
    /// 旧版 codex 无 Stop/UPS 事件时写入不触发、无副作用。
    static func codexHooksDict(scriptPath: String = ClaudeHookPreferences.helperScriptPath) -> [String: Any] {
        var hooks: [String: Any] = [:]
        // B132 形状对齐：事件值必须为 entry 数组（与远程生成器 generateCodexHooksDictJSON
        // 及 isHookInstalled 认可的规范形状一致）；此前裸字典让本地装机与远程通道分裂，
        // 且 cleanVibeFocusHooks（[[String:Any]] 语义）对裸字典卸载失灵。
        hooks["SessionStart"] = [ClaudeHookPreferences.makeHookEntry(scriptPath: scriptPath)]
        hooks["Stop"] = [ClaudeHookPreferences.makeHookEntry(scriptPath: scriptPath)]
        hooks["PermissionRequest"] = [ClaudeHookPreferences.makeHookEntry(scriptPath: scriptPath)]
        if ClaudeHookPreferences.autoRestoreOnPromptSubmit {
            hooks["UserPromptSubmit"] = [ClaudeHookPreferences.makeHookEntry(scriptPath: scriptPath)]
        }
        if ClaudeHookPreferences.triggerOnSessionEnd {
            hooks["SessionEnd"] = [ClaudeHookPreferences.makeHookEntry(scriptPath: scriptPath, timeout: 3)]
        }
        return hooks
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

        let path = codexConfigPath()
        let dir = codexConfigDir(home: NSHomeDirectory())

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

        // 文档变换提纯（B130）：installInstalledDocument 纯字典变换，测试直测；
        // 本函数只负责真实 IO（读旧文档 → 变换 → 原子写）。
        let existingData = try? Data(contentsOf: URL(fileURLWithPath: path))
        let (document, hookEvents) = installedDocument(
            existingData: existingData,
            triggerOnSessionEnd: ClaudeHookPreferences.triggerOnSessionEnd,
            autoRestoreOnPromptSubmit: ClaudeHookPreferences.autoRestoreOnPromptSubmit,
            scriptPath: ClaudeHookPreferences.helperScriptPath,
            targetURL: ClaudeHookPreferences.endpointURLString()
        )

        log(
            "[CodexHookPreferences] installing hooks",
            fields: [
                "path": path,
                "hookEvents": hookEvents.joined(separator: ","),
                "helperScript": ClaudeHookPreferences.helperScriptPath
            ]
        )

        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) else {
            return (false, "无法序列化 JSON")
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            log("[CodexHookPreferences] hooks installed successfully to \(path)")
            // 信任提示进安装结果文案：codex 按 hooks 内容 hash 记忆信任，注册集
            // 有变化（含开关翻转增删事件）后未重新信任会被静默跳过——不说这话
            // 用户会把「事件不到达」误判成 VibeFocus 坏了。
            return (true, "已安装到 Codex（\(path)）。hooks 有变更时需在 Codex TUI 执行 /hooks 重新信任，否则事件会被静默跳过")
        } catch {
            log("[CodexHookPreferences] install write failed: \(error.localizedDescription)", level: .error)
            return (false, "写入失败: \(error.localizedDescription)")
        }
    }

    /// 从 Codex ~/.codex/hooks.json 移除 VibeFocus hook
    static func uninstallHookFromCodexSettings(
        at path: String = codexConfigPath(),
        scriptPath: String = ClaudeHookPreferences.helperScriptPath,
        targetURL: String = ClaudeHookPreferences.endpointURLString()
    ) -> (Bool, String) {
        // P-INST-284: Codex hook 卸载耗时（Data(contentsOf codexConfigPath) 读 + JSONSerialization 解析 + cleanVibeFocusHooks 清理 + JSONSerialization 编码 + atomic write；设置面板 Codex 卸载按钮调用）。
        #if PERF_INSTRUMENT
        let uhStart = Date()
        defer {
            log("[CodexHookPreferences] uninstallHookFromCodexSettings finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: uhStart))
            ])
        }
        #endif
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            // 文件不存在视为已卸载
            return (true, "Codex 配置不存在，无需卸载")
        }
        let document = uninstalledDocument(existingData: data, scriptPath: scriptPath, targetURL: targetURL)
        log("[CodexHookPreferences] uninstalling hooks from \(path)", fields: ["topKeys": document.keys.sorted().joined(separator: ",")])

        guard let outputData = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) else {
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

    /// 安装后的 codex 文档（纯变换，B130）：读旧文档数据 → 规范形状合并 +
    /// 历史错形状迁移清理。返回 (新文档, 实际注册事件集)。B207：autoRestoreOnPromptSubmit
    /// 从调用方线程化进来（此前硬编码 false 把 UPS 永远裁掉——当时 codex 无 UPS 事件，
    /// B207 起 codex 支持 UPS，按「提交后自动归位」开关注册）。
    static func installedDocument(
        existingData: Data?,
        triggerOnSessionEnd: Bool,
        autoRestoreOnPromptSubmit: Bool,
        scriptPath: String,
        targetURL: String
    ) -> (document: [String: Any], hookEvents: [String]) {
        var document: [String: Any] = [:]
        if let existingData,
           let existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            document = existing
        }
        var wrapped = (document["hooks"] as? [String: Any]) ?? [:]
        wrapped = mergedHooks(
            existing: wrapped,
            ourHooks: codexHooksDict(scriptPath: scriptPath),
            triggerOnSessionEnd: triggerOnSessionEnd,
            autoRestoreOnPromptSubmit: autoRestoreOnPromptSubmit,
            scriptPath: scriptPath,
            targetURL: targetURL
        )
        cleanVibeFocusHooks(from: &document, scriptPath: scriptPath, targetURL: targetURL)
        // B130 语义补齐：历史错形状的顶层事件键整体降级（该形状 codex 解析失败整文件
        // 不加载，顶层事件无可达语义；我方条目已迁入规范 hooks 层，foreign 条目一并弃置）
        for key in ["SessionStart", "Stop", "SessionEnd", "UserPromptSubmit", "PermissionRequest"] {
            document.removeValue(forKey: key)
        }
        document["hooks"] = wrapped
        return (document, wrapped.keys.sorted())
    }

    /// 卸载后的 codex 文档（纯变换，B130）：双形状清理我方条目，其余原样保留。
    static func uninstalledDocument(existingData: Data, scriptPath: String, targetURL: String) -> [String: Any] {
        guard var document = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            return [:]
        }
        if var wrapped = document["hooks"] as? [String: Any] {
            cleanVibeFocusHooks(from: &wrapped, scriptPath: scriptPath, targetURL: targetURL)
            document["hooks"] = wrapped
        }
        cleanVibeFocusHooks(from: &document, scriptPath: scriptPath, targetURL: targetURL)
        return document
    }

    /// 合并语义唯一事实源（纯字典变换，B32 提纯）：清理旧 VibeFocus 条目 → 并入新条目 →
    /// 按触发开关裁剪事件。install 的正文与测试共用，消除「改安装语义必须同步改测试副本」的漂移面。
    static func mergedHooks(
        existing: [String: Any],
        ourHooks: [String: Any],
        triggerOnSessionEnd: Bool,
        autoRestoreOnPromptSubmit: Bool,
        scriptPath: String,
        targetURL: String
    ) -> [String: Any] {
        var hooks = existing
        cleanVibeFocusHooks(from: &hooks, scriptPath: scriptPath, targetURL: targetURL)
        for (key, value) in ourHooks {
            hooks[key] = value
        }
        // 与 Claude Code 安装逻辑保持一致：根据触发开关移除不需要的事件
        if !triggerOnSessionEnd { hooks.removeValue(forKey: "SessionEnd") }
        if !autoRestoreOnPromptSubmit { hooks.removeValue(forKey: "UserPromptSubmit") }
        return hooks
    }

    /// 从 hooks 字典中清理所有 VibeFocus 相关的 hook 条目（Codex hooks.json 顶层即事件键名）。
    /// B46 统一判据：识别走 HookSettingsComposition 唯一事实源（url 精确相等 OR command 含
    /// 脚本路径）——此前本地内联仅按 command 匹配，url 形态旧条目漏删（双份判据漂移修复）；
    /// `targetURL` 注入（B32/B46）——测试免真身脚本路径与端口。
    static func cleanVibeFocusHooks(
        from hooks: inout [String: Any],
        scriptPath: String,
        targetURL: String
    ) {
        log("[CodexHookPreferences] cleanVibeFocusHooks() entered", level: .debug, fields: [
            "keysBefore": hooks.keys.sorted().joined(separator: ",")
        ])
        for key in ["SessionStart", "Stop", "SessionEnd", "UserPromptSubmit", "PermissionRequest"] {
            guard let entries = hooks[key] as? [[String: Any]] else { continue }
            let stripped = HookSettingsComposition.stripVibeFocusEntries(
                from: entries, targetURL: targetURL, scriptPath: scriptPath)
            if stripped.kept.isEmpty { hooks.removeValue(forKey: key) }
            else { hooks[key] = stripped.kept }
            log("[CodexHookPreferences] cleanVibeFocusHooks() cleaned \(key)", level: .debug, fields: [
                "removed": String(stripped.removed)
            ])
        }
    }
}
