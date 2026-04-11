import Foundation

enum ClaudeHookPreferences {
    static let enabledKey = "claudeHookEnabled"
    static let portKey = "claudeHookPort"
    static let tokenKey = "claudeHookToken"
    static let autoFocusOnSessionEndKey = "claudeHookAutoFocusOnSessionEnd"
    static let triggerOnStopKey = "claudeHookTriggerOnStop"
    static let triggerOnSessionEndKey = "claudeHookTriggerOnSessionEnd"

    static let endpointPath = "/claude/hook"
    static let defaultPort = 39277

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    static var listenPort: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: portKey)
            if stored == 0 {
                return defaultPort
            }
            return normalizePort(stored)
        }
        set {
            UserDefaults.standard.set(normalizePort(newValue), forKey: portKey)
        }
    }

    static var authToken: String? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: tokenKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return nil
            }
            return raw
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            UserDefaults.standard.set(trimmed, forKey: tokenKey)
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
            UserDefaults.standard.object(forKey: autoFocusOnSessionEndKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoFocusOnSessionEndKey)
        }
    }

    static var triggerOnStop: Bool {
        get { UserDefaults.standard.object(forKey: triggerOnStopKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: triggerOnStopKey) }
    }

    static var triggerOnSessionEnd: Bool {
        get { UserDefaults.standard.object(forKey: triggerOnSessionEndKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: triggerOnSessionEndKey) }
    }

    static func endpointURLString(port: Int? = nil) -> String {
        let effectivePort = normalizePort(port ?? listenPort)
        let token = authToken ?? ""
        if token.isEmpty {
            return "http://127.0.0.1:\(effectivePort)\(endpointPath)"
        }
        return "http://127.0.0.1:\(effectivePort)\(endpointPath)?token=\(token)"
    }

    static func hookCommandExample(port: Int? = nil, token: String? = nil) -> String {
        let effectivePort = normalizePort(port ?? listenPort)
        let tokenHeader = token?.isEmpty == false
            ? "  \\\n  -H 'X-VibeFocus-Token: \(token!)'"
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

    private static func normalizePort(_ value: Int) -> Int {
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
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: claudeSettingsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }
        let targetURL = endpointURLString()
        for (_, entries) in hooks {
            guard let entryList = entries as? [[String: Any]] else { continue }
            for entry in entryList {
                guard let hookList = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in hookList {
                    if let url = hook["url"] as? String, url == targetURL {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Hook Config Generation

    private static func makeHookEntry(url: String) -> [String: Any] {
        [
            "matcher": "",
            "hooks": [
                ["type": "http", "url": url, "timeout": 5]
            ]
        ]
    }

    static func generateHooksDict() -> [String: Any] {
        let url = endpointURLString()
        var hooks: [String: Any] = [:]
        hooks["SessionStart"] = [makeHookEntry(url: url)]
        if triggerOnStop {
            hooks["Stop"] = [makeHookEntry(url: url)]
        }
        if triggerOnSessionEnd {
            hooks["SessionEnd"] = [makeHookEntry(url: url)]
        }
        return hooks
    }

    static func generateHooksJSON() -> String {
        let hooks = generateHooksDict()
        let settings: [String: Any] = ["hooks": hooks]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{\n  \"hooks\": {}\n}"
        }
        return json
    }

    /// 安全 merge Hook 到 Claude settings.json
    /// 只覆盖 SessionStart/Stop/SessionEnd 三个 key，保留用户其他 hooks 和配置
    static func installHookToClaudeSettings() -> (Bool, String) {
        ensureTokenGenerated()
        let path = claudeSettingsPath
        let dir = claudeSettingsDir

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
        let ourHooks = generateHooksDict()
        for (key, value) in ourHooks {
            existingHooks[key] = value
        }
        if !triggerOnStop { existingHooks.removeValue(forKey: "Stop") }
        if !triggerOnSessionEnd { existingHooks.removeValue(forKey: "SessionEnd") }
        settings["hooks"] = existingHooks

        log(
            "[ClaudeHookPreferences] installing hooks",
            fields: [
                "path": path,
                "hookEvents": existingHooks.keys.sorted().joined(separator: ","),
                "totalSettingsKeys": String(settings.count)
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

    /// 从 Claude settings.json 中精确移除 VibeFocus Hook
    static func uninstallHookFromClaudeSettings() -> (Bool, String) {
        let path = claudeSettingsPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else {
            return (false, "无法读取 Claude 配置")
        }

        let targetURL = endpointURLString()
        for key in ["SessionStart", "Stop", "SessionEnd"] {
            guard var entries = hooks[key] as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { $0["url"] as? String == targetURL }
            }
            if entries.isEmpty { hooks.removeValue(forKey: key) }
            else { hooks[key] = entries }
        }

        settings["hooks"] = hooks.isEmpty ? nil : hooks

        log("[ClaudeHookPreferences] uninstalling hooks from \(path)", fields: ["remainingEvents": hooks.keys.sorted().joined(separator: ",")])

        guard let outputData = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else {
            return (false, "无法序列化配置")
        }
        do {
            try outputData.write(to: URL(fileURLWithPath: path), options: .atomic)
            log("[ClaudeHookPreferences] hooks uninstalled successfully")
            return (true, "已移除 Hook")
        } catch {
            log("[ClaudeHookPreferences] uninstall write failed: \(error.localizedDescription)", level: .error)
            return (false, "写入失败: \(error.localizedDescription)")
        }
    }
}
