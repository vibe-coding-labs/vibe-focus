import Foundation

enum ClaudeHookPreferences {
    /// 防止 hook 安装被频繁重复调用 — UserDefaults 是线程安全的
    private static let lastInstallAtKey = "claudeHookLastInstallAt"
    private static let installCooldown: TimeInterval = 3.0

    static let enabledKey = "claudeHookEnabled"
    static let portKey = "claudeHookPort"
    static let tokenKey = "claudeHookToken"
    static let autoFocusOnSessionEndKey = "claudeHookAutoFocusOnSessionEnd"
    static let triggerOnStopKey = "claudeHookTriggerOnStop"
    static let triggerOnSessionEndKey = "claudeHookTriggerOnSessionEnd"
    static let autoRestoreOnPromptSubmitKey = "claudeHookAutoRestoreOnPromptSubmit"

    static let endpointPath = "/claude/hook"
    static let defaultPort = 39277

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
            let value = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
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
            UserDefaults.standard.object(forKey: autoFocusOnSessionEndKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoFocusOnSessionEndKey)
            PreferencesSync.persistToDisk()
        }
    }

    static var triggerOnStop: Bool {
        get { UserDefaults.standard.object(forKey: triggerOnStopKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: triggerOnStopKey)
            PreferencesSync.persistToDisk()
        }
    }

    static var triggerOnSessionEnd: Bool {
        get { UserDefaults.standard.object(forKey: triggerOnSessionEndKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: triggerOnSessionEndKey)
            PreferencesSync.persistToDisk()
        }
    }

    static var autoRestoreOnPromptSubmit: Bool {
        get { UserDefaults.standard.object(forKey: autoRestoreOnPromptSubmitKey) as? Bool ?? false }
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

    // MARK: - Hook Config Generation

    /// 写入辅助脚本配置文件（端口和 Token）
    static func writeConfigFile() {
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
        log("ClaudeHookPreferences.removeHelperFiles() entered", level: .debug, fields: [
            "scriptPath": helperScriptPath,
            "configPath": configFilePath
        ])
        try? FileManager.default.removeItem(atPath: helperScriptPath)
        try? FileManager.default.removeItem(atPath: configFilePath)
        log("[ClaudeHookPreferences] helper files removed")
    }

    /// 生成辅助脚本内容：读取 stdin JSON，捕获终端环境变量，转发到 VibeFocus HTTP 端点
    private static func generateHelperScriptContent() -> String {
        let hostBlock = LANHookPreferences.lanMode ? """
        VF_HOST=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('host','127.0.0.1'))" 2>/dev/null || echo "127.0.0.1")

""" : ""
        let hostDefault = LANHookPreferences.lanMode ? "$VF_HOST" : "127.0.0.1"
        return """
        #!/bin/bash
        set -euo pipefail

        # VibeFocus Hook Forwarder
        # Captures terminal context and forwards Claude Code hook events to VibeFocus

        VF_CONFIG="$HOME/.vibefocus/hook-config.json"
        VF_PORT=39277
        VF_TOKEN=""
        \(hostBlock)
        if [ -f "$VF_CONFIG" ]; then
            VF_PORT=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('port',39277))" 2>/dev/null || echo "39277")
            VF_TOKEN=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('token',''))" 2>/dev/null || echo "")
        fi

        VF_PAYLOAD=$(cat)

        VF_TSID="${TERM_SESSION_ID:-}"
        VF_ISID="${ITERM_SESSION_ID:-}"
        VF_KWID="${KITTY_WINDOW_ID:-}"
        VF_WP="${WEZTERM_PANE:-}"
        VF_TTY=$(tty 2>/dev/null || echo "")
        VF_PPID="${PPID:-}"
        VF_CPD="${CLAUDE_PROJECT_DIR:-}"
        VF_WID="${WINDOWID:-}"

        VF_ENRICHED=$(printf '%s' "$VF_PAYLOAD" | python3 -c "
        import sys, json
        d = json.load(sys.stdin)
        d['terminal_ctx'] = {
            'term_session_id': sys.argv[1],
            'iterm_session_id': sys.argv[2],
            'kitty_window_id': sys.argv[3],
            'wezterm_pane': sys.argv[4],
            'tty': sys.argv[5],
            'ppid': sys.argv[6],
            'claude_project_dir': sys.argv[7],
            'window_id': sys.argv[8]
        }
        print(json.dumps(d))
        " "$VF_TSID" "$VF_ISID" "$VF_KWID" "$VF_WP" "$VF_TTY" "$VF_PPID" "$VF_CPD" "$VF_WID" 2>/dev/null || printf '%s' "$VF_PAYLOAD")

        VF_URL="http://\(hostDefault):$VF_PORT/claude/hook"
        VF_CURL_ARGS=(-sS -X POST "$VF_URL" -H "Content-Type: application/json")
        if [ -n "$VF_TOKEN" ]; then
            VF_CURL_ARGS+=(-H "X-VibeFocus-Token: $VF_TOKEN")
        fi
        VF_CURL_ARGS+=(--data "$VF_ENRICHED")
        curl "${VF_CURL_ARGS[@]}" >/dev/null 2>&1 || true
        """
    }

    // MARK: - Remote Install Script

    /// 生成远程安装脚本：用户复制到远程机器执行即可完成 Hook 配置
    static func generateRemoteInstallScript(host: String) -> String {
        let port = listenPort
        let token = authToken ?? ""
        let machineLabel = "remote-\(host.replacingOccurrences(of: ".", with: "-"))"

        let hookConfigJSON = """
        {
          "host": "\(host)",
          "port": \(port),
          "token": "\(token)",
          "machine_label": "\(machineLabel)"
        }
        """

        let scriptContent = generateRemoteHelperScriptContent()
        let hooksJSON = generateHooksJSON()

        return """
        #!/bin/bash
        set -euo pipefail

        # VibeFocus Remote Hook Installer
        # 在运行 Claude Code 的机器上执行此脚本，自动配置 Hook 事件转发到 VibeFocus
        # 生成时间: \(ISO8601DateFormatter().string(from: Date()))
        # 目标: \(host):\(port)

        echo "=== VibeFocus Remote Hook Installer ==="
        echo "Target: \(host):\(port)"
        echo ""

        # 检测 python3
        if ! command -v python3 &>/dev/null; then
          echo "ERROR: python3 not found. Hook forwarder requires python3."
          echo "Install with: brew install python3 || apt install python3"
          exit 1
        fi

        # 检测 jq（可选，用于 settings.json merge）
        HAS_JQ=false
        if command -v jq &>/dev/null; then
          HAS_JQ=true
        fi

        # 1. 创建配置目录
        mkdir -p ~/.vibefocus
        echo "[1/4] Created ~/.vibefocus/"

        # 2. 写入 hook-config.json
        cat > ~/.vibefocus/hook-config.json << 'HOOKCONFIG_EOF'
        \(hookConfigJSON)
        HOOKCONFIG_EOF
        echo "[2/4] Written hook-config.json (host=\(host), port=\(port))"

        # 3. 写入 hook-forwarder.sh
        cat > ~/.vibefocus/hook-forwarder.sh << 'HOOKSCRIPT_EOF'
        \(scriptContent)
        HOOKSCRIPT_EOF
        chmod 755 ~/.vibefocus/hook-forwarder.sh
        echo "[3/4] Written hook-forwarder.sh"

        # 4. 注册 Hooks 到 ~/.claude/settings.json
        CLAUDE_SETTINGS="$HOME/.claude/settings.json"
        mkdir -p "$HOME/.claude"

        if [ ! -f "$CLAUDE_SETTINGS" ]; then
          echo '{"hooks":{}}' > "$CLAUDE_SETTINGS"
        fi

        if [ "$HAS_JQ" = true ]; then
          HOOKS_JSON=\(hooksJSON.sanitizedForShell())
          CLEANED=$(jq 'del(.hooks.SessionStart) | del(.hooks.Stop) | del(.hooks.SessionEnd) | del(.hooks.UserPromptSubmit)' "$CLAUDE_SETTINGS" 2>/dev/null || cat "$CLAUDE_SETTINGS")
          echo "$CLEANED" | jq --argjson hooks "$HOOKS_JSON" '.hooks += $hooks' > "$CLAUDE_SETTINGS.tmp" 2>/dev/null && mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
          echo "[4/4] Updated ~/.claude/settings.json (via jq)"
        else
          echo "[4/4] WARNING: jq not found. Automatic settings.json update skipped."
          echo "       Add the following to your ~/.claude/settings.json manually:"
          echo ""
          echo "\(hooksJSON)"
          echo ""
        fi

        echo ""
        echo "=== Installation Complete ==="
        echo "Hook events will be forwarded to VibeFocus at \(host):\(port)"
        echo "Machine label: \(machineLabel)"
        echo ""
        echo "To uninstall: rm -rf ~/.vibefocus && edit ~/.claude/settings.json to remove hooks"
        """
    }

    /// 生成远程用的 hook-forwarder.sh 内容（始终从 config 读取 host，指向 VibeFocus 机器）
    private static func generateRemoteHelperScriptContent() -> String {
        return """
    #!/bin/bash
    set -euo pipefail

    # VibeFocus Hook Forwarder (Remote)
    # Captures terminal context and forwards Claude Code hook events to remote VibeFocus

    VF_CONFIG="$HOME/.vibefocus/hook-config.json"
    VF_HOST="127.0.0.1"
    VF_PORT=39277
    VF_TOKEN=""
    VF_LABEL=""

    if [ -f "$VF_CONFIG" ]; then
        VF_HOST=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('host','127.0.0.1'))" 2>/dev/null || echo "127.0.0.1")
        VF_PORT=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('port',39277))" 2>/dev/null || echo "39277")
        VF_TOKEN=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('token',''))" 2>/dev/null || echo "")
        VF_LABEL=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('machine_label',''))" 2>/dev/null || echo "")
    fi

    VF_PAYLOAD=$(cat)

    VF_TSID="${TERM_SESSION_ID:-}"
    VF_ISID="${ITERM_SESSION_ID:-}"
    VF_KWID="${KITTY_WINDOW_ID:-}"
    VF_WP="${WEZTERM_PANE:-}"
    VF_TTY=$(tty 2>/dev/null || echo "")
    VF_PPID="${PPID:-}"
    VF_CPD="${CLAUDE_PROJECT_DIR:-}"
    VF_WID="${WINDOWID:-}"

    VF_ENRICHED=$(printf '%s' "$VF_PAYLOAD" | python3 -c "
    import sys, json
    d = json.load(sys.stdin)
    d['terminal_ctx'] = {
        'term_session_id': sys.argv[1],
        'iterm_session_id': sys.argv[2],
        'kitty_window_id': sys.argv[3],
        'wezterm_pane': sys.argv[4],
        'tty': sys.argv[5],
        'ppid': sys.argv[6],
        'claude_project_dir': sys.argv[7],
        'window_id': sys.argv[8],
        'machine_label': sys.argv[9]
    }
    print(json.dumps(d))
    " "$VF_TSID" "$VF_ISID" "$VF_KWID" "$VF_WP" "$VF_TTY" "$VF_PPID" "$VF_CPD" "$VF_WID" "$VF_LABEL" 2>/dev/null || printf '%s' "$VF_PAYLOAD")

    VF_URL="http://$VF_HOST:$VF_PORT/claude/hook"
    VF_CURL_ARGS=(-sS -X POST "$VF_URL" -H "Content-Type: application/json")
    if [ -n "$VF_TOKEN" ]; then
        VF_CURL_ARGS+=(-H "X-VibeFocus-Token: $VF_TOKEN")
    fi
    VF_CURL_ARGS+=(--data "$VF_ENRICHED")
    curl "${VF_CURL_ARGS[@]}" >/dev/null 2>&1 || true
    """
    }

    private static func makeHookEntry() -> [String: Any] {
        [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": "bash \"\(helperScriptPath)\"", "timeout": 10]
            ]
        ]
    }

    static func generateHooksDict() -> [String: Any] {
        log("ClaudeHookPreferences.generateHooksDict() entered", level: .debug, fields: [
            "triggerOnStop": String(triggerOnStop),
            "triggerOnSessionEnd": String(triggerOnSessionEnd),
            "autoRestoreOnPromptSubmit": String(autoRestoreOnPromptSubmit)
        ])
        var hooks: [String: Any] = [:]
        hooks["SessionStart"] = [makeHookEntry()]
        if triggerOnStop {
            hooks["Stop"] = [makeHookEntry()]
        }
        if triggerOnSessionEnd {
            hooks["SessionEnd"] = [makeHookEntry()]
        }
        if autoRestoreOnPromptSubmit {
            hooks["UserPromptSubmit"] = [makeHookEntry()]
        }
        log("ClaudeHookPreferences.generateHooksDict() returning", level: .debug, fields: [
            "hookEvents": hooks.keys.sorted().joined(separator: ",")
        ])
        return hooks
    }

    static func generateHooksJSON() -> String {
        log("ClaudeHookPreferences.generateHooksJSON() entered", level: .debug)
        let hooks = generateHooksDict()
        let settings: [String: Any] = ["hooks": hooks]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            log("ClaudeHookPreferences.generateHooksJSON() failed to serialize", level: .debug)
            return "{\n  \"hooks\": {}\n}"
        }
        log("ClaudeHookPreferences.generateHooksJSON() completed", level: .debug, fields: ["length": String(json.count)])
        return json
    }

    /// 安全 merge Hook 到 Claude settings.json
    /// 只覆盖 SessionStart/Stop/SessionEnd/UserPromptSubmit 四个 key，保留用户其他 hooks 和配置
    static func installHookToClaudeSettings() -> (Bool, String) {
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
        if !triggerOnStop { existingHooks.removeValue(forKey: "Stop") }
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

extension String {
    func sanitizedForShell() -> String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
