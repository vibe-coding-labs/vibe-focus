// HookScriptGenerator.swift
// VibeFocus — Hook 脚本生成逻辑
// 从 ClaudeHookPreferences.swift 中提取，职责：生成 bash hook 脚本和 hooks JSON

import Foundation

// MARK: - Script Generation

extension ClaudeHookPreferences {

    /// 生成辅助脚本内容：读取 stdin JSON，捕获终端环境变量，转发到 VibeFocus HTTP 端点
    static func generateHelperScriptContent() -> String {
        // P-INST-198: hook 辅助脚本内容生成耗时（读 LANHookPreferences.lanMode P-INST-144 + hostBlock/hostDefault 三元 + 多行 bash 字符串插值；installHelperScript P-INST-88 调用，写 hook-forwarder.sh）。
        let ghscStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: ghscStart)
            if durMs >= 5 { log("[HookScriptGenerator] generateHelperScriptContent slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
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
    static func generateRemoteHelperScriptContent() -> String {
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

    // MARK: - Hooks JSON Generation

    static func makeHookEntry() -> [String: Any] {
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
        // Stop 始终注册：handleStop 内部根据 remoteOnly 区分本地/远程 session
        hooks["Stop"] = [makeHookEntry()]
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
        // P-INST-152: hooks JSON 序列化耗时（generateHooksDict 构建 + JSONSerialization.data withJSONObject prettyPrinted+sortedKeys；HookInstaller.applyPreferences 写 settings.json 调用，hook toggle/install 路径）。
        let ghjStart = Date()
        defer {
            log("ClaudeHookPreferences.generateHooksJSON() finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ghjStart))
            ])
        }
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
}
