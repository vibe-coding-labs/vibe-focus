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

    /// 生成远程用的 hook-forwarder.sh 内容（始终从 config 读取 host，指向 VibeFocus 机器）
    ///
    /// B169 双通道投递：直投 HTTP（--connect-timeout 1 快速失败）→ 失败落盘
    /// ~/.vibefocus/spool/（原子改名防半截读），Mac 侧 RemoteSpoolDrainer 定时
    /// ssh 拉取回灌。channel-hint 记录直投最近失败时刻，10 分钟内跳过直投
    /// （VPN 场景免每次白等 1s 超时），过期自愈重试。服务器 IP 与 ssh 用户随
    /// terminal_ctx 上报（直投可达时 Mac 顺路自注册 drain 主机）。
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
    VF_USER=$(whoami 2>/dev/null || echo "")

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
    # （B125 动态绑定）。server_ip + whoami 供 Mac 自注册 spool 拉取主机
    # （B169）。注意本段 -c 脚本被 bash 双引号包裹：python 代码与注释
    # 内不得出现双引号/$/反引号。
    conn = sys.argv[10].split() if len(sys.argv) > 10 else []
    if len(conn) >= 2:
        ctx['ssh_client_ip'] = conn[0]
        ctx['ssh_client_port'] = conn[1]
    if len(conn) >= 3:
        ctx['ssh_server_ip'] = conn[2]
    if len(sys.argv) > 11 and sys.argv[11]:
        ctx['ssh_user'] = sys.argv[11]
    d['terminal_ctx'] = ctx
    print(json.dumps(d))
    " "$VF_TSID" "$VF_ISID" "$VF_KWID" "$VF_WP" "$VF_TTY" "$VF_PPID" "$VF_CPD" "$VF_WID" "$VF_LABEL" "$VF_SSHC" "$VF_USER" 2>/dev/null || printf '%s' "$VF_PAYLOAD")

    # ---- B169 双通道投递：直投 → 落盘（Mac 侧定时 ssh 拉取）----
    VF_SPOOL_DIR="$HOME/.vibefocus/spool"
    VF_HINT_FILE="$HOME/.vibefocus/direct-hint"
    VF_HINT_TTL=600

    VF_TRY_DIRECT=1
    if [ -f "$VF_HINT_FILE" ]; then
        VF_HINT_AT=$(cat "$VF_HINT_FILE" 2>/dev/null || echo 0)
        case "$VF_HINT_AT" in ''|*[!0-9]*) VF_HINT_AT=0 ;; esac
        VF_NOW=$(date +%s)
        if [ "$VF_NOW" -lt $((VF_HINT_AT + VF_HINT_TTL)) ]; then
            VF_TRY_DIRECT=0
        fi
    fi

    VF_URL="http://$VF_HOST:$VF_PORT/claude/hook"
    VF_SENT=0
    if [ "$VF_TRY_DIRECT" = "1" ]; then
        VF_CURL_ARGS=(-sS -X POST "$VF_URL" -H "Content-Type: application/json")
        if [ -n "$VF_TOKEN" ]; then
            VF_CURL_ARGS+=(-H "X-VibeFocus-Token: $VF_TOKEN")
        fi
        VF_CURL_ARGS+=(--data "$VF_ENRICHED" --connect-timeout 1 --max-time 4)
        if curl "${VF_CURL_ARGS[@]}" >/dev/null 2>&1; then
            VF_SENT=1
            rm -f "$VF_HINT_FILE" 2>/dev/null || true
        else
            date +%s > "$VF_HINT_FILE" 2>/dev/null || true
        fi
    fi

    if [ "$VF_SENT" = "0" ]; then
        mkdir -p "$VF_SPOOL_DIR" 2>/dev/null || true
        VF_STAMP="$(date +%s)-$$-${RANDOM:-0}"
        printf '%s\n' "$VF_ENRICHED" > "$VF_SPOOL_DIR/.tmp-$VF_STAMP" 2>/dev/null || true
        mv "$VF_SPOOL_DIR/.tmp-$VF_STAMP" "$VF_SPOOL_DIR/$VF_STAMP.json" 2>/dev/null || true
        # 挤压积压上限：只留最新 200 个（Mac 长期失联时防无限膨胀）
        ls -t "$VF_SPOOL_DIR" 2>/dev/null | tail -n +201 | while IFS= read -r f; do
            rm -f "$VF_SPOOL_DIR/$f" 2>/dev/null || true
        done
    fi
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
