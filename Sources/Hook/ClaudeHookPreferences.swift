import Foundation

/// Manages Claude Code hook integration preferences and auto-installation.
enum ClaudeHookPreferences {
    /// 防止 hook 安装被频繁重复调用 — UserDefaults 是线程安全的
    static let lastInstallAtKey = "claudeHookLastInstallAt"
    static let installCooldown: TimeInterval = 3.0

    static let enabledKey = "claudeHookEnabled"
    static let portKey = "claudeHookPort"
    static let tokenKey = "claudeHookToken"
    static let autoFocusOnSessionEndKey = "claudeHookAutoFocusOnSessionEnd"
    static let triggerOnStopKey = "claudeHookTriggerOnStop"
    static let triggerOnSessionEndKey = "claudeHookTriggerOnSessionEnd"
    static let autoRestoreOnPromptSubmitKey = "claudeHookAutoRestoreOnPromptSubmit"

    static let endpointPath = "/claude/hook"
    static let defaultPort = 39277

    // MARK: - 统一默认值（唯一源）
    // 所有默认值只在这里定义一次，SettingsUI 引用这些常量，
    // 编译器保证一致性，防止默认值漂移导致 app 重启后配置被重置。

    static let defaultEnabled = false
    static let defaultAutoFocusOnSessionEnd = true
    static let defaultTriggerOnStop = true
    static let defaultTriggerOnSessionEnd = false
    static let defaultAutoRestoreOnPromptSubmit = true

    static var helperScriptDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".vibefocus")
    }

    static var helperScriptPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".vibefocus/hook-forwarder.sh")
    }

    static var configFilePath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".vibefocus/hook-config.json")
    }

    static var isEnabled: Bool {
        // P-INST-232: hook 启用状态访问耗时（UserDefaults.object 读 / UserDefaults.set CFPreferences 同步写；hook handler 每请求 + applyPreferences P-INST-77 高频读，设置 UI toggle 写；slow-op ≥5ms warn）。
        get {
            let geStart = Date()
            let value = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
            let durMs = elapsedMilliseconds(since: geStart)
            log("ClaudeHookPreferences.isEnabled read", level: durMs >= 5 ? .warn : .debug, fields: ["value": String(value), "durationMs": String(durMs)])
            return value
        }
        set {
            let seStart = Date()
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            let durMs = elapsedMilliseconds(since: seStart)
            log("ClaudeHookPreferences.isEnabled set", level: durMs >= 5 ? .warn : .debug, fields: ["value": String(newValue), "durationMs": String(durMs)])
        }
    }

    static var listenPort: Int {
        // P-INST-233: hook 监听端口访问耗时（UserDefaults.integer 读 / UserDefaults.set CFPreferences 同步写；applyPreferences P-INST-77 启动读 + server startIfNeeded，设置 UI 写；slow-op ≥5ms warn）。
        get {
            let geStart = Date()
            let stored = UserDefaults.standard.integer(forKey: portKey)
            let durMs = elapsedMilliseconds(since: geStart)
            if stored == 0 {
                log("ClaudeHookPreferences.listenPort read: using default", level: durMs >= 5 ? .warn : .debug, fields: ["defaultPort": String(defaultPort), "durationMs": String(durMs)])
                return defaultPort
            }
            let normalized = normalizePort(stored)
            log("ClaudeHookPreferences.listenPort read", level: durMs >= 5 ? .warn : .debug, fields: ["stored": String(stored), "normalized": String(normalized), "durationMs": String(durMs)])
            return normalized
        }
        set {
            let normalized = normalizePort(newValue)
            let seStart = Date()
            UserDefaults.standard.set(normalized, forKey: portKey)
            let durMs = elapsedMilliseconds(since: seStart)
            log("ClaudeHookPreferences.listenPort set", level: durMs >= 5 ? .warn : .debug, fields: ["raw": String(newValue), "normalized": String(normalized), "durationMs": String(durMs)])
        }
    }

    static var authToken: String? {
        // P-INST-234: hook auth token 访问耗时（UserDefaults.string 读 / UserDefaults.set CFPreferences 同步写；hook handler 鉴权每请求读 + ensureTokenGenerated P-INST-187 写，设置 UI 写；slow-op ≥5ms warn）。
        get {
            let geStart = Date()
            guard let raw = UserDefaults.standard.string(forKey: tokenKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                let durMs = elapsedMilliseconds(since: geStart)
                log("ClaudeHookPreferences.authToken read: nil or empty", level: durMs >= 5 ? .warn : .debug, fields: ["durationMs": String(durMs)])
                return nil
            }
            let durMs = elapsedMilliseconds(since: geStart)
            log("ClaudeHookPreferences.authToken read", level: durMs >= 5 ? .warn : .debug, fields: ["tokenPrefix": String(raw.prefix(8)) + "...", "durationMs": String(durMs)])
            return raw
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let seStart = Date()
            UserDefaults.standard.set(trimmed, forKey: tokenKey)
            let durMs = elapsedMilliseconds(since: seStart)
            log("ClaudeHookPreferences.authToken set", level: durMs >= 5 ? .warn : .debug, fields: ["hasValue": String(!trimmed.isEmpty), "durationMs": String(durMs)])
        }
    }

    /// 确保已生成 token，如果没有则自动生成一个
    @discardableResult
    static func ensureTokenGenerated() -> String {
        // P-INST-187: hook auth token 生成耗时（UUID().uuidString 生成 + authToken setter CFPreferences 同步写；hook server 启动 + 设置 UI 生成 token 调用，已存在则直接返回跳过写）。
        let etgStart = Date()
        if let existing = authToken, !existing.isEmpty {
            let durMs = elapsedMilliseconds(since: etgStart)
            if durMs >= 5 { log("[ClaudeHookPreferences] ensureTokenGenerated(cached) slow", level: .warn, fields: ["durationMs": String(durMs)]) }
            return existing
        }
        let generated = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(32)
            .lowercased()
        authToken = generated
        let durMs = elapsedMilliseconds(since: etgStart)
        if durMs >= 5 { log("[ClaudeHookPreferences] ensureTokenGenerated(generate) slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        log(
            "[ClaudeHookPreferences] auto-generated auth token",
            fields: ["tokenPrefix": String(generated.prefix(8)) + "..."]
        )
        return generated
    }

    static var autoFocusOnSessionEnd: Bool {
        // P-INST-235: SessionEnd 自动聚焦开关访问耗时（UserDefaults.object 读 / set CFPreferences 写；generateHooksDict 决定是否注册 SessionEnd hook 读，设置 UI 写；slow-op ≥5ms warn）。
        get {
            let gStart = Date()
            let value = UserDefaults.standard.object(forKey: autoFocusOnSessionEndKey) as? Bool ?? defaultAutoFocusOnSessionEnd
            let durMs = elapsedMilliseconds(since: gStart)
            if durMs >= 5 { log("ClaudeHookPreferences.autoFocusOnSessionEnd read slow", level: .warn, fields: ["durationMs": String(durMs)]) }
            return value
        }
        set {
            let sStart = Date()
            UserDefaults.standard.set(newValue, forKey: autoFocusOnSessionEndKey)
            let durMs = elapsedMilliseconds(since: sStart)
            if durMs >= 5 { log("ClaudeHookPreferences.autoFocusOnSessionEnd set slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
    }

    static var triggerOnStop: Bool {
        // P-INST-236: Stop hook 触发开关访问耗时（UserDefaults.object 读 / set CFPreferences 写；generateHooksDict 决定 Stop hook 行为读，设置 UI 写；slow-op ≥5ms warn）。
        get {
            let gStart = Date()
            let value = UserDefaults.standard.object(forKey: triggerOnStopKey) as? Bool ?? defaultTriggerOnStop
            let durMs = elapsedMilliseconds(since: gStart)
            if durMs >= 5 { log("ClaudeHookPreferences.triggerOnStop read slow", level: .warn, fields: ["durationMs": String(durMs)]) }
            return value
        }
        set {
            let sStart = Date()
            UserDefaults.standard.set(newValue, forKey: triggerOnStopKey)
            let durMs = elapsedMilliseconds(since: sStart)
            if durMs >= 5 { log("ClaudeHookPreferences.triggerOnStop set slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
    }

    static var triggerOnSessionEnd: Bool {
        // P-INST-237: SessionEnd hook 触发开关访问耗时（UserDefaults.object 读 / set CFPreferences 写；generateHooksDict 决定是否注册 SessionEnd hook 读，设置 UI 写；slow-op ≥5ms warn）。
        get {
            let gStart = Date()
            let value = UserDefaults.standard.object(forKey: triggerOnSessionEndKey) as? Bool ?? defaultTriggerOnSessionEnd
            let durMs = elapsedMilliseconds(since: gStart)
            if durMs >= 5 { log("ClaudeHookPreferences.triggerOnSessionEnd read slow", level: .warn, fields: ["durationMs": String(durMs)]) }
            return value
        }
        set {
            let sStart = Date()
            UserDefaults.standard.set(newValue, forKey: triggerOnSessionEndKey)
            let durMs = elapsedMilliseconds(since: sStart)
            if durMs >= 5 { log("ClaudeHookPreferences.triggerOnSessionEnd set slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
    }

    static var autoRestoreOnPromptSubmit: Bool {
        // P-INST-238: UserPromptSubmit 自动 restore 开关访问耗时（UserDefaults.object 读 / set CFPreferences 写；generateHooksDict 决定是否注册 UserPromptSubmit hook 读，设置 UI 写；slow-op ≥5ms warn）。
        get {
            let gStart = Date()
            let value = UserDefaults.standard.object(forKey: autoRestoreOnPromptSubmitKey) as? Bool ?? defaultAutoRestoreOnPromptSubmit
            let durMs = elapsedMilliseconds(since: gStart)
            if durMs >= 5 { log("ClaudeHookPreferences.autoRestoreOnPromptSubmit read slow", level: .warn, fields: ["durationMs": String(durMs)]) }
            return value
        }
        set {
            let sStart = Date()
            UserDefaults.standard.set(newValue, forKey: autoRestoreOnPromptSubmitKey)
            let durMs = elapsedMilliseconds(since: sStart)
            if durMs >= 5 { log("ClaudeHookPreferences.autoRestoreOnPromptSubmit set slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
    }

    static func endpointURLString(port: Int? = nil) -> String {
        let effectivePort = normalizePort(port ?? listenPort)
        let token = authToken ?? ""
        log("ClaudeHookPreferences.endpointURLString()", level: .debug, fields: [
            "port": String(effectivePort),
            "hasToken": String(!token.isEmpty)
        ])
        if token.isEmpty {
            return "http://127.0.0.1:\(effectivePort)\(endpointPath)"
        }
        return "http://127.0.0.1:\(effectivePort)\(endpointPath)?token=\(token)"
    }

    static func hookCommandExample(port: Int? = nil, token: String? = nil) -> String {
        let effectivePort = normalizePort(port ?? listenPort)
        let tokenHeader = token?.isEmpty == false
            ? "  \\\n  -H 'X-VibeFocus-Token: \(token ?? "")'"
            : ""
        return """
#!/bin/bash
set -euo pipefail

EVENT="$1" # SessionStart or SessionEnd
PAYLOAD="$(cat)"
SESSION_ID="$(echo "$PAYLOAD" | jq -r '.session_id // .sessionId // empty' 2>/dev/null || true)"
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="unknown-session"
fi

curl -sS -X POST "http://127.0.0.1:\(effectivePort)/claude/hook" \
  -H "Content-Type: application/json"\(tokenHeader) \
  --data "{\"event\":\"$EVENT\",\"session_id\":\"$SESSION_ID\",\"source\":\"claude-code-hook\"}" >/dev/null || true
"""
    }

    static func normalizePort(_ value: Int) -> Int {
        min(max(value, 1024), 65535)
    }

    // MARK: - Claude Settings Integration

    static var claudeSettingsPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    }

    static var claudeSettingsDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }

    static var claudeSettingsExists: Bool {
        // P-INST-84: claude settings.json 存在性探测耗时（FileManager.fileExists stat 调用；设置面板 UI 状态 + isHookInstalled 前置条件检查；通常 <1ms）。
        let cseStart = Date()
        defer {
            log("ClaudeHookPreferences.claudeSettingsExists checked", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: cseStart))
            ])
        }
        return FileManager.default.fileExists(atPath: claudeSettingsPath)
    }

    static var isHookInstalled: Bool {
        // P-INST-82: hook 安装状态检查耗时（Data(contentsOf claudeSettingsPath) + JSONSerialization 解析 + hooks 字典遍历匹配；设置面板 UI 状态渲染调用；文件读 + JSON 解析在 settings 较大时可阻塞）。
        let ihiStart = Date()
        defer {
            log("ClaudeHookPreferences.isHookInstalled finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ihiStart))
            ])
        }
        log("ClaudeHookPreferences.isHookInstalled checking", level: .debug)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: claudeSettingsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            log("ClaudeHookPreferences.isHookInstalled: no hooks found in settings", level: .debug)
            return false
        }
        // 兼容检测 command-type hooks（新）和 HTTP-type hooks（旧）
        let targetURL = endpointURLString()
        let scriptPath = helperScriptPath
        for (key, entries) in hooks {
            guard let entryList = entries as? [[String: Any]] else { continue }
            for entry in entryList {
                guard let hookList = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in hookList {
                    // 新版 command-type hook
                    if let command = hook["command"] as? String, command.contains(scriptPath) {
                        log("ClaudeHookPreferences.isHookInstalled: found command hook", level: .debug, fields: ["event": key])
                        return true
                    }
                    // 旧版 HTTP-type hook（向后兼容）
                    if let url = hook["url"] as? String, url == targetURL {
                        log("ClaudeHookPreferences.isHookInstalled: found HTTP hook", level: .debug, fields: ["event": key])
                        return true
                    }
                }
            }
        }
        log("ClaudeHookPreferences.isHookInstalled: no matching hooks found", level: .debug)
        return false
    }

    // 脚本生成逻辑已移至 HookScriptGenerator.swift
    // 安装/卸载逻辑已移至 HookInstaller.swift
}

extension String {
    func sanitizedForShell() -> String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
