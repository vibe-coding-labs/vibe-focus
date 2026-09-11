// RemoteInstallScriptBuilder.swift
// VibeFocus — 远程一键安装脚本组装（B127 自 HookScriptGenerator 拆分，逐字搬移零行为变更）
// 职责：把 hook-config.json / forwarder 脚本 / Claude 与 Codex hooks 合并逻辑
// 组装成可在远程机器上独立执行的安装脚本；行为契约由 RunnerRemoteInstallTests
// 沙盒真实执行锁定。

import Foundation

// MARK: - Remote Install Script

extension ClaudeHookPreferences {

    // MARK: - Remote Install Script

    /// 生成远程安装脚本：用户复制到远程机器执行即可完成 Hook 配置
    /// 远程机器标签：host 的点转连字符（hook-config.json 的 machine_label 与安装脚本展示共用同一事实源）
    static func machineLabel(forHost host: String) -> String {
        "remote-\(host.replacingOccurrences(of: ".", with: "-"))"
    }

    /// 远程 hook-config.json 模板（install 脚本写入远程 ~/.vibefocus/hook-config.json 的唯一形状）。
    /// extraHosts 非空时附 "hosts" 候选数组（B168）：host 仍是主地址（旧版转发器
    /// 兼容字段），hosts = 主地址 + 备选（VPN 隧道地址等），转发器按序逐个试连。
    static func hookConfigJSON(host: String, port: Int, token: String, machineLabel: String, extraHosts: [String] = []) -> String {
        var hostSection = "  \"host\": \"\(host)\","
        if !extraHosts.isEmpty {
            let items = extraHosts.map { "    \"\($0)\"" }.joined(separator: ",\n")
            hostSection += "\n  \"hosts\": [\n\(items)\n  ],"
        }
        return """
        {
        \(hostSection)
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

    static func generateRemoteInstallScript(host: String, port: Int, token: String, labelOverride: String? = nil, extraHosts: [String] = []) -> String {
        let label = labelOverride ?? machineLabel(forHost: host)
        let fallbackHosts = extraHosts.filter { $0 != host }
        let hookConfig = hookConfigJSON(host: host, port: port, token: token, machineLabel: label, extraHosts: fallbackHosts)

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

}
