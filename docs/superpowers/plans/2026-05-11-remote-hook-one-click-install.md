# Remote Hook One-Click Install

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 让用户在设置窗口中一键生成远程安装命令，复制到远程机器执行即可完成 Claude Hook 配置。远程机器上的 Claude Code 事件将自动转发到本机 VibeFocus。

**Architecture:** 用户开启 LAN 模式 → 设置窗口显示本机 IP + 生成的自包含安装脚本 → 用户复制到远程机器执行 → 脚本自动创建 `~/.vibefocus/` 目录、写入 hook-config.json（含 VibeFocus IP/端口/Token）、写入 hook-forwarder.sh、修改 `~/.claude/settings.json` 注册 hooks。复用现有 `generateHelperScriptContent()` 和 `generateHooksDict()` 逻辑。

**Tech Stack:** Swift 5.9, macOS 13+, SwiftUI, GCDWebServer

**Risks:**
- 生成的脚本包含明文 Token → 缓解：UI 中明确提醒"仅在可信网络使用"，卸载时远程机器需手动清理
- 远程机器可能没有 python3（hook-forwarder.sh 依赖） → 缓解：脚本开头检测 python3 可用性
- 远程机器的 `~/.claude/settings.json` 可能已有其他 hooks → 缓解：复用现有安全 merge 逻辑（只覆盖 4 个事件 key）

---

### Task 1: 在 ClaudeHookPreferences 添加远程安装脚本生成方法

**Depends on:** None
**Files:**
- Modify: `Sources/ClaudeHookPreferences.swift:342-351`（在 `makeHookEntry()` 之前添加新方法）

- [ ] **Step 1: 添加 `generateRemoteInstallScript()` 方法 — 生成自包含的远程安装脚本**

文件: `Sources/ClaudeHookPreferences.swift`（在 `generateHelperScriptContent()` 方法之后，`makeHookEntry()` 之前插入）

```swift
    /// 生成远程安装脚本：用户复制到远程机器执行即可完成 Hook 配置
    /// host: VibeFocus 所在机器的 LAN IP
    static func generateRemoteInstallScript(host: String) -> String {
        let port = listenPort
        let token = authToken ?? ""
        let machineLabel = "remote-\(host.replacingOccurrences(of: ".", with: "-"))"

        // 生成远程用的 hook-config.json 内容（host 指向 VibeFocus 机器）
        let hookConfigJSON = """
        {
          "host": "\(host)",
          "port": \(port),
          "token": "\(token)",
          "machine_label": "\(machineLabel)"
        }
        """

        // 生成远程用的 hook-forwarder.sh（从 host 字段读取 VibeFocus IP）
        let scriptContent = generateRemoteHelperScriptContent()

        // 生成 hooks JSON（用于 ~/.claude/settings.json merge）
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
          # 使用 jq 安全 merge
          HOOKS_JSON=\(hooksJSON.sanitizedForShell())
          # 移除旧的 VibeFocus hooks
          CLEANED=$(jq 'del(.hooks.SessionStart) | del(.hooks.Stop) | del(.hooks.SessionEnd) | del(.hooks.UserPromptSubmit)' "$CLAUDE_SETTINGS" 2>/dev/null || cat "$CLAUDE_SETTINGS")
          # merge 新 hooks
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
```

注意：`generateRemoteHelperScriptContent()` 与现有 `generateHelperScriptContent()` 的区别是：
1. 始终从 config 读取 `host` 字段（不是硬编码 127.0.0.1）
2. 始终读取 `machine_label` 字段并注入到 payload 的 `terminal_ctx` 中
3. `generateRemoteInstallScript()` 中引用了 `.sanitizedForShell()` — 需要在下方 Step 2 添加这个 String extension

- [ ] **Step 2: 添加 String shell 转义辅助方法**

文件: `Sources/ClaudeHookPreferences.swift`（在文件末尾，class 外部添加）

```swift
extension String {
    func sanitizedForShell() -> String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
```

- [ ] **Step 3: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/ClaudeHookPreferences.swift && git commit -m "feat(hook): add remote install script generation"`

---

### Task 2: 在 LANSettingsView 添加远程安装 UI

**Depends on:** Task 1
**Files:**
- Modify: `Sources/LANSettingsView.swift:37-72`（在 `lanDetailSection` 中添加远程安装 section）

- [ ] **Step 1: 添加远程安装 UI — 显示生成的安装命令和复制按钮**

文件: `Sources/LANSettingsView.swift`（在 `lanDetailSection` 的 `addMachineRow` 之后，最后的 Text 之前插入）

```swift
            Divider()

            remoteInstallSection
```

然后在 `LANSettingsView` struct 中添加 `remoteInstallSection` computed property 和相关状态：

在 `@State var newMachineLabel = ""` 之后添加：
```swift
    @State var remoteInstallMessage: String?
    @State var remoteInstallSucceeded = true
```

在 `private var addMachineRow` 之后添加：
```swift
    private var remoteInstallSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("远程一键安装")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
                    .font(.system(size: 12))
                Text("复制以下命令，在运行 Claude Code 的远程机器终端执行即可。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)

            let lanIP = LANHookPreferences.currentLANIP()
            let installScript = ClaudeHookPreferences.generateRemoteInstallScript(host: lanIP)

            ScrollView {
                Text(installScript)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
            }
            .frame(maxHeight: 200)

            HStack(spacing: 12) {
                Button("复制安装命令") {
                    let lanIP = LANHookPreferences.currentLANIP()
                    let script = ClaudeHookPreferences.generateRemoteInstallScript(host: lanIP)
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(script, forType: .string)
                    pb.setString(script, forType: .string)
                    remoteInstallMessage = "已复制到剪贴板（\(script.count) 字符）"
                    remoteInstallSucceeded = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("复制 curl 一行命令") {
                    let lanIP = LANHookPreferences.currentLANIP()
                    let script = ClaudeHookPreferences.generateRemoteInstallScript(host: lanIP)
                    let encoded = script.data(using: .utf8)?.base64EncodedString() ?? ""
                    let oneLiner = "echo '\(encoded)' | base64 -d | bash"
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(oneLiner, forType: .string)
                    remoteInstallMessage = "已复制一行命令（\(oneLiner.count) 字符）"
                    remoteInstallSucceeded = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }

            if let msg = remoteInstallMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(remoteInstallSucceeded ? .green : .red)
            }

            Text("注意：安装命令包含认证 Token，仅在可信网络中使用。卸载需在远程机器手动清理 ~/.vibefocus 和 ~/.claude/settings.json。")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
```

- [ ] **Step 2: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/LANSettingsView.swift && git commit -m "feat(ui): add remote hook one-click install section in LAN settings"`

---

## Self-Review Results

| # | Check | Result | Action Taken |
|---|-------|--------|-------------|
| 1 | Header? | PASS | Goal + Architecture + Tech Stack + Risks |
| 2 | Dependencies? | PASS | Task 2 depends on Task 1 |
| 3 | File paths? | PASS | 精确到文件和行号 |
| 4 | 3-8 Steps/Task? | PASS | Task 1: 4, Task 2: 3 |
| 5 | New file complete code? | N/A | 无新文件 |
| 6 | Modify complete function? | PASS | 提供了完整方法代码 |
| 7 | Code block size? | PASS | 最大 ~80 行 |
| 8 | No dangling references? | PASS | 所有引用的方法/类型已存在 |
| 9 | Validation commands? | PASS | 每个 Task 有 swift build |
| 10 | Coverage complete? | PASS | 覆盖脚本生成 + UI |
| 11 | Independent verification? | PASS | 每个 Task 独立编译 |
| 12 | No TBD/TODO? | PASS | 无占位符 |
| 13 | No vague instructions? | PASS | 所有 Step 有具体代码 |
| 14 | Cross-task consistency? | PASS | `generateRemoteInstallScript(host:)` 签名一致 |
| 15 | Save location? | PASS | docs/superpowers/plans/ |

**Status:** ✅ ALL PASS

---

## Execution Selection

**Tasks:** 2
**Dependencies:** Task 2 depends on Task 1
**User Preference:** none
**Decision:** Inline
**Reasoning:** 2 个 Task 修改量小且顺序执行，inline 更快

**Auto-invoking:** 直接执行
