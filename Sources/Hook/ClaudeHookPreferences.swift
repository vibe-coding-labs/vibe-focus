import Foundation

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
    // 所有默认值只在这里定义一次，SettingsUI 和 PreferencesSync 引用这些常量，
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
        get {
            let value = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
            log("ClaudeHookPreferences.isEnabled read", level: .debug, fields: ["value": String(value)])
            return value
        }
        set {
            log("ClaudeHookPreferences.isEnabled set", level: .debug, fields: ["value": String(newValue)])
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            PreferencesSync.persistToDisk()
        }
    }

    static var listenPort: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: portKey)
            if stored == 0 {
                log("ClaudeHookPreferences.listenPort read: using default", level: .debug, fields: ["defaultPort": String(defaultPort)])
                return defaultPort
            }
            let normalized = normalizePort(stored)
            log("ClaudeHookPreferences.listenPort read", level: .debug, fields: ["stored": String(stored), "normalized": String(normalized)])
            return normalized
        }
        set {
            let normalized = normalizePort(newValue)
            log("ClaudeHookPreferences.listenPort set", level: .debug, fields: ["raw": String(newValue), "normalized": String(normalized)])
            UserDefaults.standard.set(normalized, forKey: portKey)
            PreferencesSync.persistToDisk()
        }
    }

    static var authToken: String? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: tokenKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                log("ClaudeHookPreferences.authToken read: nil or empty", level: .debug)
                return nil
            }
            log("ClaudeHookPreferences.authToken read", level: .debug, fields: ["tokenPrefix": String(raw.prefix(8)) + "..."])
            return raw
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            log("ClaudeHookPreferences.authToken set", level: .debug, fields: ["hasValue": String(!trimmed.isEmpty)])
            UserDefaults.standard.set(trimmed, forKey: tokenKey)
            PreferencesSync.persistToDisk()
        }
    }

    /// 确保已生成 token，如果没有则自动生成一个
    @discardableResult
    static func ensureTokenGenerated() -> String {
        if let existing = authToken, !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(32)
            .lowercased()
        authToken = generated
        log(
            "[ClaudeHookPreferences] auto-generated auth token",
            fields: ["tokenPrefix": String(generated.prefix(8)) + "..."]
        )
        return generated
    }

    static var autoFocusOnSessionEnd: Bool {
        get {
            UserDefaults.standard.object(forKey: autoFocusOnSessionEndKey) as? Bool ?? defaultAutoFocusOnSessionEnd
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoFocusOnSessionEndKey)
            PreferencesSync.persistToDisk()
        }
    }

    static var triggerOnStop: Bool {
        get { UserDefaults.standard.object(forKey: triggerOnStopKey) as? Bool ?? defaultTriggerOnStop }
        set {
            UserDefaults.standard.set(newValue, forKey: triggerOnStopKey)
            PreferencesSync.persistToDisk()
        }
    }

    static var triggerOnSessionEnd: Bool {
        get { UserDefaults.standard.object(forKey: triggerOnSessionEndKey) as? Bool ?? defaultTriggerOnSessionEnd }
        set {
            UserDefaults.standard.set(newValue, forKey: triggerOnSessionEndKey)
            PreferencesSync.persistToDisk()
        }
    }

    static var autoRestoreOnPromptSubmit: Bool {
        get { UserDefaults.standard.object(forKey: autoRestoreOnPromptSubmitKey) as? Bool ?? defaultAutoRestoreOnPromptSubmit }
        set {
            UserDefaults.standard.set(newValue, forKey: autoRestoreOnPromptSubmitKey)
            PreferencesSync.persistToDisk()
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
        FileManager.default.fileExists(atPath: claudeSettingsPath)
    }

    static var isHookInstalled: Bool {
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
