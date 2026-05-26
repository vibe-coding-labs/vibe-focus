# Research: 跨机器 ClaudeHook 实现状态分析

**Question:** VibeFocus 的 LAN ClaudeHook 功能实现到什么程度？`local-server-002` 作为 SSH 开发机器能否正常使用？
**Context:** 用户在局域网有 `local-server-002` 作为 SSH 开发机器，需要确认跨机器 Hook 是否可用。
**Deliverable:** 当前实现状态 + 配置指南 + 已知问题
**Time Box:** 已完成（30 分钟调研）
**Scope:** Small
**Plan Type:** Research

---

## 架构总览

```
┌─────────────────────────┐         HTTP POST          ┌──────────────────────────┐
│   local-server-002      │ ──────────────────────────→ │   macOS (VibeFocus)      │
│   (SSH 开发机)           │    http://192.168.x.x:39277 │                          │
│                          │    /claude/hook             │  ClaudeHookServer        │
│  Claude Code             │    Header: X-VibeFocus-Token│  (GCDWebServer, 0.0.0.0)│
│  ├─ ~/.claude/           │                             │                          │
│  │  settings.json        │    Payload:                 │  HookEventHandler        │
│  │  (hooks 配置)          │    {event, session_id,     │  ├─ 解析 machine_label   │
│  ├─ ~/.vibefocus/        │     terminal_ctx: {         │  ├─ 查 remoteBindings    │
│  │  hook-forwarder.sh    │       machine_label:        │  └─ 映射到 CGWindowID   │
│  │  hook-config.json     │         "local-server-002"  │                          │
│  └─ python3 (依赖)       │     }}                      │  WindowManager           │
│                          │                             │  └─ 窗口管理操作         │
└─────────────────────────┘                             └──────────────────────────┘
```

## 实现状态

### 已完成的功能

| # | 功能 | 文件 | 状态 |
|---|------|------|------|
| 1 | LAN 模式切换（绑定 0.0.0.0） | `LANHookPreferences.swift` / `ClaudeHookServer.swift` | ✅ |
| 2 | 本机 LAN IP 自动检测（en0） | `LANHookPreferences.currentLANIP()` | ✅ |
| 3 | 远程机器标签管理 | `LANHookPreferences.remoteBindings` | ✅ |
| 4 | 标签→CGWindowID 映射 | `LANHookPreferences.activeRemoteBindings` | ✅ |
| 5 | Token 认证 | `ClaudeHookServer.isTokenValid/resolveProvidedToken` | ✅ |
| 6 | machine_label 传递 | `generateRemoteHelperScriptContent()` L466/492 | ✅ |
| 7 | 远程安装脚本生成 | `generateRemoteInstallScript(host:)` L357-445 | ✅ |
| 8 | 远程 hook-forwarder.sh | `generateRemoteHelperScriptContent()` L448-505 | ✅ |
| 9 | 远程绑定解析 | `HookEventHandler+Remote.swift` L8-38 | ✅ |
| 10 | LAN 设置 UI | `LANSettingsView.swift` | ✅ |
| 11 | 一键安装命令（含 base64 编码） | `LANSettingsView.swift` L189-209 | ✅ |
| 12 | Claude settings.json 自动 merge | `generateRemoteInstallScript` 内 jq 逻辑 | ✅ |

### 配置步骤（local-server-002）

**Step 1: macOS 端（VibeFocus）**
1. 打开 VibeFocus 设置 → Claude 集成 → 局域网 Hook
2. 开启"局域网模式"
3. 点击"添加"，输入 `local-server-002` 作为 machine_label
4. 点击"映射当前窗口"，选中终端窗口

**Step 2: 远程机器端（local-server-002）**
1. 复制"远程一键安装"脚本（或 base64 一行命令）
2. SSH 到 `local-server-002` 执行脚本
3. 脚本自动完成：
   - 创建 `~/.vibefocus/hook-config.json`（含 host/port/token/machine_label）
   - 创建 `~/.vibefocus/hook-forwarder.sh`（捕获终端上下文 + machine_label）
   - 注册 hooks 到 `~/.claude/settings.json`（需要 jq）

**Step 3: 验证**
- 在 `local-server-002` 上启动 Claude Code 会话
- VibeFocus 应收到 SessionStart hook 并绑定到映射的窗口

### 已知限制和风险

| # | 问题 | 严重程度 | 说明 |
|---|------|---------|------|
| 1 | machine_label 默认值为 `remote-192-168-x-x` | 低 | `generateRemoteInstallScript` L360 自动生成，用户可在安装后手动改 `hook-config.json` |
| 2 | 映射窗口需要手动操作 | 中 | 用户必须在 macOS 端点击"映射当前窗口"绑定 CGWindowID |
| 3 | CGWindowID 重启后会变化 | 中 | 每次重启 macOS 后需要重新映射 |
| 4 | 无 SSL/TLS | 低 | 仅 HTTP，依赖局域网安全。Token 认证可防未授权访问 |
| 5 | 依赖 python3 | 中 | hook-forwarder.sh 用 python3 做 JSON enrichment，远程机器必须有 python3 |
| 6 | 依赖 jq（可选） | 低 | 无 jq 时需手动编辑 settings.json |
| 7 | 无连接状态监控 | 低 | 无法在 UI 中看到远程机器是否在线/最近 hook 时间 |
| 8 | 终端上下文在 SSH 环境可能不完整 | 中 | SSH 会话的 TTY、TERM_SESSION_ID 等环境变量可能与本地不同 |

### 数据流细节

**hook-forwarder.sh（远程机器）执行流程：**
1. 读取 `~/.vibefocus/hook-config.json` 获取 host/port/token/machine_label
2. 从 stdin 读取 Claude Code 发送的 JSON payload
3. 捕获终端环境变量（TERM_SESSION_ID, ITERM_SESSION_ID, TTY, PPID 等）
4. 用 python3 将环境变量注入 payload 的 `terminal_ctx` 字段
5. 添加 `machine_label` 到 `terminal_ctx`
6. curl POST 到 `http://<host>:<port>/claude/hook`

**ClaudeHookServer（macOS 端）处理流程：**
1. 验证 Token（query param 或 X-VibeFocus-Token header）
2. 解码 `ClaudeHookPayload`（含 `terminalCtx.machineLabel`）
3. 检查 `isRemote`（有 machine_label）
4. 调用 `resolveRemoteBinding(label:sessionID:)` 查映射表
5. 根据 event 类型执行窗口操作（SessionStart → 绑定，SessionEnd → toggle）

### 信息源

| # | 来源 | 路径/行号 |
|---|------|----------|
| 1 | LANHookPreferences | `Sources/Hook/LANHookPreferences.swift` |
| 2 | 远程安装脚本生成 | `Sources/Hook/ClaudeHookPreferences.swift:357-445` |
| 3 | 远程 hook-forwarder | `Sources/Hook/ClaudeHookPreferences.swift:448-505` |
| 4 | 远程绑定解析 | `Sources/Hook/HookEventHandler+Remote.swift:8-38` |
| 5 | Token 认证 | `Sources/Hook/ClaudeHookServer.swift` |
| 6 | LAN 设置 UI | `Sources/Settings/LANSettingsView.swift` |
| 7 | TerminalContext 模型 | `Sources/Hook/ClaudeHookModels.swift:156-203` |

## 结论

**实现状态：功能完整，可用于生产。**

跨机器 ClaudeHook 功能已完整实现，包括：
- 一键远程安装脚本（自动配置 hook-config.json + hook-forwarder.sh + settings.json）
- machine_label 传递和窗口映射
- Token 认证保护

**对 `local-server-002` 的建议配置：**
1. 安装脚本默认 machine_label 为 `remote-<ip>`，建议手动改为 `local-server-002` 以便于识别
2. 确保 `local-server-002` 有 python3（hook-forwarder 依赖）
3. 建议安装 jq 以自动更新 settings.json
4. macOS 端映射窗口后，CGWindowID 会随重启变化，需要重新映射
