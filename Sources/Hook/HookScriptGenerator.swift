// HookScriptGenerator.swift
// VibeFocus — Hook 脚本生成逻辑
// 从 ClaudeHookPreferences.swift 中提取，职责：生成 bash hook 脚本和 hooks JSON

import Foundation

// MARK: - Script Generation

extension ClaudeHookPreferences {

    /// 生成辅助脚本内容：读取 stdin JSON，捕获终端环境变量，转发到 VibeFocus HTTP 端点
    /// （默认入口读 LANHookPreferences.lanMode；lanMode 参数版是 P-INST-144 的测试缝，直测免 UserDefaults）
    static func generateHelperScriptContent() -> String {
        generateHelperScriptContent(lanMode: LANHookPreferences.lanMode)
    }

    static func generateHelperScriptContent(lanMode: Bool) -> String {
        // P-INST-198: hook 辅助脚本内容生成耗时（读 LANHookPreferences.lanMode P-INST-144 + hostBlock/hostDefault 三元 + 多行 bash 字符串插值；installHelperScript P-INST-88 调用，写 hook-forwarder.sh）。
        #if PERF_INSTRUMENT
        let ghscStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: ghscStart)
            if durMs >= 5 { log("[HookScriptGenerator] generateHelperScriptContent slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
        let hostBlock = lanMode ? """
        VF_HOST=$(python3 -c "import json;d=json.load(open('$VF_CONFIG'));print(d.get('host','127.0.0.1'))" 2>/dev/null || echo "127.0.0.1")

""" : ""
        let hostDefault = lanMode ? "$VF_HOST" : "127.0.0.1"
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
    /// 远程机器标签：host 的点转连字符（hook-config.json 的 machine_label 与安装脚本展示共用同一事实源）
    static func machineLabel(forHost host: String) -> String {
        "remote-\(host.replacingOccurrences(of: ".", with: "-"))"
    }

    /// 远程 hook-config.json 模板（install 脚本写入远程 ~/.vibefocus/hook-config.json 的唯一形状）
    static func hookConfigJSON(host: String, port: Int, token: String, machineLabel: String) -> String {
        """
        {
          "host": "\(host)",
          "port": \(port),
          "token": "\(token)",
          "machine_label": "\(machineLabel)"
        }
        """
    }

    /// 便捷入口：读当前偏好生成（端口/token 真 身）。部署工具链（--print-remote-install-script）
    /// 走显式参数入口，避免 CLI 裸二进制写 UserDefaults 副作用。
    static func generateRemoteInstallScript(host: String) -> String {
        generateRemoteInstallScript(host: host, port: listenPort, token: authToken ?? "")
    }

    static func generateRemoteInstallScript(host: String, port: Int, token: String, labelOverride: String? = nil) -> String {
        let label = labelOverride ?? machineLabel(forHost: host)
        let hookConfig = hookConfigJSON(host: host, port: port, token: token, machineLabel: label)

        let scriptContent = generateRemoteHelperScriptContent()
        // hook 命令路径必须 $HOME 形态：远程家目录 ≠ Mac 家目录，
        // 真身绝对路径在远程不存在，hook 会静默空转（真机 002 实锤）
        let hooksJSON = generateHooksDictJSON(scriptPath: remoteHelperScriptPath)
        let codexHooksJSON = generateCodexHooksDictJSON(scriptPath: remoteHelperScriptPath)
        let codexEvents = triggerOnSessionEnd ? "SessionStart + SessionEnd" : "SessionStart"

        return """
        #!/bin/bash
        set -euo pipefail

        # VibeFocus Remote Hook Installer
        # 在运行 Claude Code / Codex 的远程机器上执行此脚本，自动配置 Hook 事件转发到 VibeFocus
        # 生成时间: \(ISO8601DateFormatter().string(from: Date()))
        # 目标: \(host):\(port)

        echo "=== VibeFocus Remote Hook Installer ==="
        echo "Target: \(host):\(port)"
        echo ""

        # 检测 python3（硬前置：forwarder 与配置合并都依赖；无 jq 时合并走 python3 降级）
        if ! command -v python3 &>/dev/null; then
          echo "ERROR: python3 not found. Hook forwarder requires python3."
          echo "Install with: brew install python3 || apt install python3"
          exit 1
        fi

        # 检测 jq（可选：settings.json 合并优先 jq，缺失走 python3 降级）
        HAS_JQ=false
        if command -v jq &>/dev/null; then
          HAS_JQ=true
        fi

        # 1/6 创建配置目录
        mkdir -p ~/.vibefocus
        echo "[1/6] Created ~/.vibefocus/"

        # 2/6 写入 hook-config.json
        cat > ~/.vibefocus/hook-config.json << 'HOOKCONFIG_EOF'
        \(hookConfig)
        HOOKCONFIG_EOF
        echo "[2/6] Written hook-config.json (host=\(host), port=\(port))"

        # 3/6 写入 hook-forwarder.sh
        cat > ~/.vibefocus/hook-forwarder.sh << 'HOOKSCRIPT_EOF'
        \(scriptContent)
        HOOKSCRIPT_EOF
        chmod 755 ~/.vibefocus/hook-forwarder.sh
        echo "[3/6] Written hook-forwarder.sh"

        # 4/6 注册 Hooks 到 ~/.claude/settings.json（jq 优先，缺失 python3 降级；保留既有配置）
        CLAUDE_SETTINGS="$HOME/.claude/settings.json"
        mkdir -p "$HOME/.claude"

        if [ ! -f "$CLAUDE_SETTINGS" ]; then
          echo '{}' > "$CLAUDE_SETTINGS"
        fi

        if [ "$HAS_JQ" = true ]; then
          HOOKS_JSON=\(hooksJSON.sanitizedForShell())
          CLEANED=$(jq 'del(.hooks.SessionStart) | del(.hooks.Stop) | del(.hooks.SessionEnd) | del(.hooks.UserPromptSubmit)' "$CLAUDE_SETTINGS" 2>/dev/null || cat "$CLAUDE_SETTINGS")
          echo "$CLEANED" | jq --argjson hooks "$HOOKS_JSON" '.hooks += $hooks' > "$CLAUDE_SETTINGS.tmp" 2>/dev/null && mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
          echo "[4/6] Updated ~/.claude/settings.json (via jq)"
        else
          python3 - "$CLAUDE_SETTINGS" << 'PYCLAUDE_EOF'
        import json, os, sys
        path = sys.argv[1]
        try:
            with open(path) as f:
                settings = json.load(f)
        except Exception:
            settings = {}
        if not isinstance(settings, dict):
            settings = {}
        hooks = settings.get("hooks")
        if not isinstance(hooks, dict):
            hooks = {}
        MARKER = ".vibefocus/hook-forwarder.sh"
        def strip(entries):
            kept = []
            for e in entries:
                if isinstance(e, dict):
                    hs = e.get("hooks")
                    if isinstance(hs, list) and any(
                        isinstance(h, dict) and MARKER in str(h.get("command", "")) for h in hs
                    ):
                        continue
                kept.append(e)
            return kept
        for ev in ("SessionStart", "Stop", "SessionEnd", "UserPromptSubmit"):
            if isinstance(hooks.get(ev), list):
                hooks[ev] = strip(hooks[ev])
        OUR = json.loads(r'''\(hooksJSON)''')
        hooks.update(OUR)
        settings["hooks"] = hooks
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(settings, f, indent=2, ensure_ascii=False)
            f.write("\\n")
        os.replace(tmp, path)
        PYCLAUDE_EOF
          echo "[4/6] Updated ~/.claude/settings.json (via python3)"
        fi

        # 5/6 注册 Hooks 到 ~/.codex/hooks.json（Codex 0.153+：事件字典必须包在顶层
        # "hooks" 字段下；codex 事件集无 Stop/UserPromptSubmit，只写可触发的
        # \(codexEvents)。首次在 Codex TUI 运行如提示信任 hook，请确认。）
        CODEX_HOOKS="$HOME/.codex/hooks.json"
        mkdir -p "$HOME/.codex"
        python3 - "$CODEX_HOOKS" << 'PYCODEX_EOF'
        import json, os, sys
        path = sys.argv[1]
        doc = {}
        if os.path.exists(path):
            try:
                with open(path) as f:
                    doc = json.load(f)
            except Exception:
                doc = {}
        if not isinstance(doc, dict):
            doc = {}
        hooks = doc.get("hooks")
        if not isinstance(hooks, dict):
            hooks = {}
        MARKER = ".vibefocus/hook-forwarder.sh"
        def strip(entries):
            kept = []
            for e in entries:
                if isinstance(e, dict):
                    hs = e.get("hooks")
                    if isinstance(hs, list) and any(
                        isinstance(h, dict) and MARKER in str(h.get("command", "")) for h in hs
                    ):
                        continue
                kept.append(e)
            return kept
        for ev in ("SessionStart", "Stop", "SessionEnd", "UserPromptSubmit"):
            if isinstance(hooks.get(ev), list):
                hooks[ev] = strip(hooks[ev])
        for ev in ("SessionStart", "Stop", "SessionEnd", "UserPromptSubmit"):
            if isinstance(doc.get(ev), list):
                doc[ev] = strip(doc[ev])
        OUR = json.loads(r'''\(codexHooksJSON)''')
        hooks.update(OUR)
        doc["hooks"] = hooks
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(doc, f, indent=2, ensure_ascii=False)
            f.write("\\n")
        os.replace(tmp, path)
        PYCODEX_EOF
        echo "[5/6] Updated ~/.codex/hooks.json (codex events: \(codexEvents))"

        echo ""
        echo "=== Installation Complete ==="
        echo "Hook events will be forwarded to VibeFocus at \(host):\(port)"
        echo "Machine label: \(label)"
        echo "Codex: hooks.json registered (\(codexEvents)); trust prompt on first TUI run."
        echo ""
        echo "To uninstall: rm -rf ~/.vibefocus && remove the VibeFocus hook entries from ~/.claude/settings.json and ~/.codex/hooks.json"
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
    VF_SSHC="${SSH_CLIENT:-}"

    VF_ENRICHED=$(printf '%s' "$VF_PAYLOAD" | python3 -c "
    import sys, json
    d = json.load(sys.stdin)
    ctx = {
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
    # SSH_CLIENT = client_ip client_port server_ip server_port
    # client_port 是 Mac 侧 ssh 进程的本地 TCP 端口，服务端据此反查本机窗口
    # （B125 动态绑定）。注意本段 -c 脚本被 bash 双引号包裹：python 代码与注释
    # 内不得出现双引号/$/反引号。
    conn = sys.argv[10].split() if len(sys.argv) > 10 else []
    if len(conn) >= 2:
        ctx['ssh_client_ip'] = conn[0]
        ctx['ssh_client_port'] = conn[1]
    if len(conn) >= 3:
        ctx['ssh_server_ip'] = conn[2]
    d['terminal_ctx'] = ctx
    print(json.dumps(d))
    " "$VF_TSID" "$VF_ISID" "$VF_KWID" "$VF_WP" "$VF_TTY" "$VF_PPID" "$VF_CPD" "$VF_WID" "$VF_LABEL" "$VF_SSHC" 2>/dev/null || printf '%s' "$VF_PAYLOAD")

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

    static func makeHookEntry(scriptPath: String = helperScriptPath) -> [String: Any] {
        [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": "bash \"\(scriptPath)\"", "timeout": 10]
            ]
        ]
    }

    /// 远程安装脚本的 hook 命令路径：远程机器的家目录与 Mac 不同，必须用 $HOME
    /// 形态——写 Mac 绝对路径（真身 helperScriptPath）在远程是致命静默断链
    ///（路径不存在、hook 命令空转、事件零转发）。
    static let remoteHelperScriptPath = "$HOME/.vibefocus/hook-forwarder.sh"

    static func makeRemoteHookEntry() -> [String: Any] {
        makeHookEntry(scriptPath: remoteHelperScriptPath)
    }

    static func generateHooksDict(scriptPath: String = helperScriptPath) -> [String: Any] {
        log("ClaudeHookPreferences.generateHooksDict() entered", level: .debug, fields: [
            "triggerOnStop": String(triggerOnStop),
            "triggerOnSessionEnd": String(triggerOnSessionEnd),
            "autoRestoreOnPromptSubmit": String(autoRestoreOnPromptSubmit)
        ])
        var hooks: [String: Any] = [:]
        hooks["SessionStart"] = [makeHookEntry(scriptPath: scriptPath)]
        // Stop 始终注册：handleStop 内部根据 remoteOnly 区分本地/远程 session
        hooks["Stop"] = [makeHookEntry(scriptPath: scriptPath)]
        if triggerOnSessionEnd {
            hooks["SessionEnd"] = [makeHookEntry(scriptPath: scriptPath)]
        }
        if autoRestoreOnPromptSubmit {
            hooks["UserPromptSubmit"] = [makeHookEntry(scriptPath: scriptPath)]
        }
        log("ClaudeHookPreferences.generateHooksDict() returning", level: .debug, fields: [
            "hookEvents": hooks.keys.sorted().joined(separator: ",")
        ])
        return hooks
    }

    static func generateHooksJSON() -> String {
        // P-INST-152: hooks JSON 序列化耗时（generateHooksDict 构建 + JSONSerialization.data withJSONObject prettyPrinted+sortedKeys；HookInstaller.applyPreferences 写 settings.json 调用，hook toggle/install 路径）。
        #if PERF_INSTRUMENT
        let ghjStart = Date()
        defer {
            log("ClaudeHookPreferences.generateHooksJSON() finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: ghjStart))
            ])
        }
        #endif
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

    /// 仅 hooks 字典的 JSON（不含顶层 "hooks" 包裹）——远程安装脚本 jq 合并用：
    /// `.hooks += $hooks` 的右侧必须是「事件名 → 条目」字典本身；传整个 settings
    /// 形状会嵌套出 "hooks" 键、三个真正的事件全部静默丢失（B84 实锤复现于
    /// 沙盒 HOME 行为测试）。
    static func generateHooksDictJSON(scriptPath: String = helperScriptPath) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: generateHooksDict(scriptPath: scriptPath), options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// Codex hooks.json 的事件字典 JSON（不含顶层 "hooks" 包裹，与远程安装脚本的
    /// python 合并语义对齐：读 doc["hooks"] 清理后 update）。事件集 = codex 可触发的
    /// SessionStart 恒注册 + SessionEnd 按开关——codex 0.153.4 实证事件集
    /// （PreToolUse/PermissionRequest/PostToolUse/PreCompact/PostCompact/SessionStart/
    /// SessionEnd/SubagentStart/SubagentStop/Interrupt）没有 Claude 的 Stop 与
    /// UserPromptSubmit，写了也永不触发，白条目不写。
    static func generateCodexHooksDictJSON(scriptPath: String = helperScriptPath) -> String {
        var hooks: [String: Any] = [:]
        hooks["SessionStart"] = [makeHookEntry(scriptPath: scriptPath)]
        if triggerOnSessionEnd {
            hooks["SessionEnd"] = [makeHookEntry(scriptPath: scriptPath)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: hooks, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
