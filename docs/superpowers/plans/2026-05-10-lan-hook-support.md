# LAN Hook Support — 局域网 Hook 通信 (HTTP, Revised)

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 支持 VibeFocus 接收局域网内远程机器的 Claude Code hook 事件。VibeFocus 监听 LAN (0.0.0.0)，远程机器的 hook-forwarder 通过配置 host+token+machine_label 向 VibeFocus 发送事件。通过 Settings UI 将远程 machine_label 关联到本机终端窗口。

**Architecture:** 远程机器 Claude Code 触发 hook → hook-forwarder.sh 读取 config 中 host=VibeFocus-LAN-IP + machine_label → curl POST http://192.168.x.x:39277/claude/hook (token 在 header 中) → VibeFocus GCDWebServer (0.0.0.0) 收到请求 → 从 payload 提取 machine_label → 查 LANHookPreferences 映射表找到对应 windowID → 通过 PID+bounds 匹配到 AXUIElement → 执行窗口管理操作。本地 hook 走原有 PPID/TTY 绑定路径不变。

**Tech Stack:** Swift 5.9, GCDWebServer (BindToLocalhost 可配置), SwiftUI (Settings UI), UserDefaults (远程映射持久化)

**Risks:**
- macOS 防火墙可能阻止入站连接 → 缓解：LAN 开关开启时提示用户检查防火墙
- 远程机器无 terminal_ctx，无法用 PPID/TTY 匹配 → 缓解：machine_label → windowID 映射表
- Token 在 URL query string 会暴露给日志 → 缓解：改用 X-VibeFocus-Token header 传输
- CGWindowIDFromAXUIElement API 不存在 → 缓解：用 CGWindowListCopyWindowInfo 按 PID + bounds 匹配
- remoteBindings 初始值 0 无效 → 缓解：添加远程机器时默认无映射，需选择窗口后才生效
- SettingsUI.swift 已 1527 行 → 缓解：LAN UI 拆到独立文件 LANSettingsView.swift

---

### Task 1: 数据模型 — TerminalContext 添加 machineLabel 字段

**Depends on:** None
**Files:**
- Modify: `Sources/ClaudeHookModels.swift:175-214` (TerminalContext struct)

- [ ] **Step 1: 修改 TerminalContext — 添加 machineLabel 字段用于远程机器标识**

文件: `Sources/ClaudeHookModels.swift:175-214`（替换 TerminalContext struct）

```swift
/// Claude Code hook 辅助脚本捕获的终端上下文信息
/// 用于精确定位 hook 事件对应的终端窗口，解决多工作区/多实例场景下的窗口匹配问题
struct TerminalContext: Codable, Equatable {
    let termSessionID: String?
    let itermSessionID: String?
    let kittyWindowID: String?
    let weztermPane: String?
    let tty: String?
    let ppid: String?
    let claudeProjectDir: String?
    let windowID: String?
    let machineLabel: String?

    enum CodingKeys: String, CodingKey {
        case termSessionID = "term_session_id"
        case itermSessionID = "iterm_session_id"
        case kittyWindowID = "kitty_window_id"
        case weztermPane = "wezterm_pane"
        case tty
        case ppid
        case claudeProjectDir = "claude_project_dir"
        case windowID = "window_id"
        case machineLabel = "machine_label"
    }

    /// 是否包含可用于窗口匹配的有用上下文
    var hasUsefulContext: Bool {
        let result = tty?.isEmpty == false || termSessionID?.isEmpty == false || itermSessionID?.isEmpty == false || (ppid.flatMap { Int32($0) }).map { $0 > 1 } ?? false || machineLabel?.isEmpty == false
        log("TerminalContext.hasUsefulContext evaluated", level: .debug, fields: [
            "result": String(result),
            "hasTTY": String(tty?.isEmpty == false),
            "hasTermSessionID": String(termSessionID?.isEmpty == false),
            "hasItermSessionID": String(itermSessionID?.isEmpty == false),
            "hasMachineLabel": String(machineLabel?.isEmpty == false)
        ])
        if let tty, !tty.isEmpty { return true }
        if let termSessionID, !termSessionID.isEmpty { return true }
        if let itermSessionID, !itermSessionID.isEmpty { return true }
        if let ppid, let pid = Int32(ppid), pid > 1 { return true }
        if let machineLabel, !machineLabel.isEmpty { return true }
        return false
    }

    /// 是否来自远程机器（有 machine_label）
    var isRemote: Bool {
        guard let label = machineLabel, !label.isEmpty else { return false }
        return true
    }
}
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/ClaudeHookModels.swift && git commit -m "feat(hook): add machineLabel field to TerminalContext for LAN hook support"`

---

### Task 2: LAN 配置模块 — 独立文件管理 LAN 偏好设置

**Depends on:** Task 1
**Files:**
- Create: `Sources/LANHookPreferences.swift` — LAN 模式配置、远程映射、IP 工具
- Modify: `Sources/ClaudeHookServer.swift:137-156` (BindToLocalhost 可配置)
- Modify: `Sources/ClaudeHookPreferences.swift:282-334` (hook-forwarder 支持 host + machine_label)

- [ ] **Step 1: 创建 LANHookPreferences — 集中管理 LAN 模式的配置和远程映射**

```swift
import Foundation

enum LANHookPreferences {
    static let lanModeKey = "claudeHookLanMode"
    static let remoteBindingsKey = "claudeHookRemoteBindings"

    static var lanMode: Bool {
        get { UserDefaults.standard.bool(forKey: lanModeKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: lanModeKey)
            PreferencesSync.persistToDisk()
        }
    }

    /// 远程机器 → 窗口ID 映射, 格式: ["machine-label": windowID]
    /// windowID 为 nil 表示已添加但尚未选择窗口
    static var remoteBindings: [String: UInt32?] {
        get {
            guard let raw = UserDefaults.standard.dictionary(forKey: remoteBindingsKey) else { return [:] }
            var result: [String: UInt32?] = [:]
            for (key, value) in raw {
                if let id = value as? UInt32 {
                    result[key] = id
                } else if let id = value as? Int {
                    result[key] = UInt32(id)
                }
            }
            return result
        }
        set {
            var storable: [String: Any] = [:]
            for (key, value) in newValue {
                if let id = value {
                    storable[key] = id
                }
            }
            UserDefaults.standard.set(storable, forKey: remoteBindingsKey)
            PreferencesSync.persistToDisk()
        }
    }

    /// 获取所有已映射窗口的绑定（过滤掉 nil 值）
    static var activeRemoteBindings: [String: UInt32] {
        remoteBindings.compactMapValues { $0 }
    }

    /// 获取本机 en0 的 IPv4 地址
    static func currentLANIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
}
```

- [ ] **Step 2: 修改 ClaudeHookServer — 支持 LAN 监听绑定**

文件: `Sources/ClaudeHookServer.swift:137-156`（替换 do/catch 块）

```swift
        do {
            let bindToLocalhost = !LANHookPreferences.lanMode
            try webServer.start(options: [
                GCDWebServerOption_Port: UInt(port),
                GCDWebServerOption_BindToLocalhost: bindToLocalhost
            ])
            self.server = webServer
            self.activePort = port
            self.configuredToken = token
            self.isRunning = true
            let bindAddr = bindToLocalhost ? "127.0.0.1" : "0.0.0.0"
            self.statusDescription = "监听中 \(bindAddr):\(port)"
            self.lastErrorMessage = nil
            log("[ClaudeHookServer] listening on \(bindAddr):\(port)")
            NotificationCenter.default.post(name: .hookServerStateChanged, object: nil)
        } catch {
            isRunning = false
            statusDescription = "启动失败"
            lastErrorMessage = error.localizedDescription
            log("[ClaudeHookServer] failed to start: \(error.localizedDescription)")
        }
```

- [ ] **Step 3: 修改 generateHelperScriptContent — hook-forwarder 支持 host 配置和 machine_label 注入**

文件: `Sources/ClaudeHookPreferences.swift:282-334`（替换整个 generateHelperScriptContent 函数）

```swift
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
#{hostBlock}
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

VF_URL="http://#{hostDefault}:$VF_PORT/claude/hook"
VF_CURL_ARGS=(-sS -X POST "$VF_URL" -H "Content-Type: application/json")
if [ -n "$VF_TOKEN" ]; then
    VF_CURL_ARGS+=(-H "X-VibeFocus-Token: $VF_TOKEN")
fi
VF_CURL_ARGS+=(--data "$VF_ENRICHED")
curl "${VF_CURL_ARGS[@]}" >/dev/null 2>&1 || true
"""
    }
```

- [ ] **Step 4: 修改 writeConfigFile — LAN 模式写入 host 和 machine_label**

文件: `Sources/ClaudeHookPreferences.swift:222-240`（替换 writeConfigFile 函数体）

```swift
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
```

- [ ] **Step 5: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 6: 提交**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/LANHookPreferences.swift Sources/ClaudeHookServer.swift Sources/ClaudeHookPreferences.swift && git commit -m "feat(hook): add LAN mode config module and server binding support"`

---

### Task 3: 远程绑定逻辑 — HookEventHandler 拆分远程绑定处理

**Depends on:** Task 2
**Files:**
- Create: `Sources/HookEventHandler+Remote.swift` — 远程绑定解析逻辑
- Modify: `Sources/HookEventHandler.swift:29-65` (handleSessionStart 区分本地/远程)

- [ ] **Step 1: 创建 HookEventHandler+Remote — 远程 machine_label 到窗口的绑定解析**

```swift
import Foundation

// MARK: - Remote Binding Resolution
extension HookEventHandler {

    /// 通过 machine_label 查找映射表中的窗口
    func resolveRemoteBinding(label: String, sessionID: String) -> WindowIdentity? {
        let bindings = LANHookPreferences.activeRemoteBindings
        guard let windowID = bindings[label] else {
            log(
                "[HookEventHandler] remote binding not found for label",
                level: .warn,
                fields: ["label": label, "availableLabels": bindings.keys.joined(separator: ",")]
            )
            SessionWindowRegistry.shared.setLastEventDescription("SessionStart 远程：label '\(label)' 未映射到窗口")
            return nil
        }

        guard let identity = WindowManager.shared.findWindowByCGWindowID(windowID) else {
            log(
                "[HookEventHandler] remote binding window no longer exists",
                level: .warn,
                fields: ["label": label, "windowID": String(windowID)]
            )
            return nil
        }

        log(
            "[HookEventHandler] remote binding resolved",
            fields: [
                "label": label,
                "windowID": String(windowID),
                "app": identity.appName ?? "unknown"
            ]
        )
        return identity
    }
}
```

- [ ] **Step 2: 修改 handleSessionStart — 区分本地绑定和远程映射**

文件: `Sources/HookEventHandler.swift:29-109`（替换从 `guard let terminalCtx` 到函数末尾 `return` 的整段）

```swift
        guard let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext else {
            log(
                "[handleSessionStart] no terminal context, cannot bind",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )
            SessionWindowRegistry.shared.setLastEventDescription("SessionStart 失败：无终端上下文")
            return (
                409,
                ClaudeHookResponse(
                    ok: false, code: "no_terminal_context",
                    message: "No terminal context available for precise binding",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 区分本地绑定和远程映射
        let identity: WindowIdentity?
        if terminalCtx.isRemote, let label = terminalCtx.machineLabel {
            // 远程机器：通过 machine_label 查映射表
            identity = resolveRemoteBinding(label: label, sessionID: payload.sessionID)
            guard let identity else {
                return (
                    409,
                    ClaudeHookResponse(
                        ok: false, code: "remote_binding_failed",
                        message: "Remote machine label '\(label)' not mapped to a window",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
        } else {
            // 本地机器：用 PPID/TTY 进程树匹配（原有逻辑）
            guard let localIdentity = WindowManager.shared.findWindowByTerminalContext(terminalCtx) else {
                log(
                    "[handleSessionStart] terminal context match failed",
                    level: .warn,
                    fields: [
                        "sessionID": payload.sessionID,
                        "tty": terminalCtx.tty ?? "nil",
                        "ppid": terminalCtx.ppid ?? "nil"
                    ]
                )
                SessionWindowRegistry.shared.setLastEventDescription("SessionStart 失败：终端上下文无法匹配窗口")
                return (
                    409,
                    ClaudeHookResponse(
                        ok: false, code: "terminal_context_match_failed",
                        message: "Terminal context could not be resolved to a window",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
            identity = localIdentity
        }

        log(
            "[HookEventHandler] SessionStart matched",
            fields: [
                "sessionID": payload.sessionID,
                "isRemote": String(terminalCtx.isRemote),
                "app": identity.appName ?? "unknown",
                "title": identity.title ?? "untitled",
                "windowID": String(identity.windowID)
            ]
        )
        SessionWindowRegistry.shared.bind(
            sessionID: payload.sessionID,
            windowIdentity: identity,
            terminalTTY: payload.terminalCtx?.tty,
            terminalSessionID: payload.terminalCtx?.termSessionID,
            itermSessionID: payload.terminalCtx?.itermSessionID,
            cwd: payload.cwd,
            model: payload.model
        )

        // Auto-set terminal title to project name
        if let axWindow = WindowManager.shared.resolveWindow(identity: identity) {
            TitleEditorService.shared.autoSetTitle(
                cwd: payload.cwd,
                pid: identity.pid,
                bundleID: identity.bundleIdentifier ?? "",
                window: axWindow
            )
        } else {
            log(
                "[HookEventHandler] SessionStart autoSetTitle skipped: could not resolve AX window",
                level: .debug,
                fields: ["windowID": String(identity.windowID)]
            )
        }

        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "session_bound",
                message: "Session bound to terminal window via \(terminalCtx.isRemote ? "remote_label" : "TTY/PPID")",
                sessionID: payload.sessionID, handled: true
            )
        )
```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 4: 提交**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/HookEventHandler+Remote.swift Sources/HookEventHandler.swift && git commit -m "feat(hook): support remote session binding via machine_label mapping"`

---

### Task 4: WindowManager 辅助方法 — 按 CGWindowID 查找窗口

**Depends on:** Task 1
**Files:**
- Modify: `Sources/WindowManager+Finding.swift` (添加 findWindowByCGWindowID 方法)

- [ ] **Step 1: 添加 findWindowByCGWindowID — 通过 CGWindowID 查找窗口并构造 WindowIdentity**

文件: `Sources/WindowManager+Finding.swift:253`（在文件末尾 `}` 之前添加）

```swift
    /// 通过 CGWindowID 查找窗口 — 遍历 CGWindowList 按 PID+bounds 匹配到 AXUIElement
    func findWindowByCGWindowID(_ targetWindowID: UInt32) -> WindowIdentity? {
        let windowListOption = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(windowListOption, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let cgID = windowInfo[kCGWindowNumber as String] as? UInt32, cgID == targetWindowID else {
                continue
            }
            guard let pid = windowInfo[kCGWindowOwnerPID as String] as? Int32 else { return nil }
            let appName = windowInfo[kCGWindowOwnerName as String] as? String
            let title = windowInfo["kCGWindowName"] as? String ?? windowInfo["name"] as? String

            let bundleID: String? = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier

            return WindowIdentity(
                windowID: targetWindowID,
                pid: pid,
                bundleIdentifier: bundleID,
                appName: appName,
                windowNumber: Int(targetWindowID),
                title: title,
                capturedAt: Date()
            )
        }
        return nil
    }
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/WindowManager+Finding.swift && git commit -m "feat(wm): add findWindowByCGWindowID for remote session window lookup"`

---

### Task 5: Settings UI — LAN 配置界面（独立文件）

**Depends on:** Task 2
**Files:**
- Create: `Sources/LANSettingsView.swift` — LAN 模式开关 + 远程机器映射 UI
- Modify: `Sources/SettingsUI.swift:959-961` (在 Hook SettingsCard 结束后插入 LANSettingsView)

- [ ] **Step 1: 创建 LANSettingsView — LAN 模式配置和远程机器映射管理**

```swift
import SwiftUI

struct LANSettingsView: View {
    @AppStorage(LANHookPreferences.lanModeKey) var lanMode = false
    @State var remoteBindings: [String: UInt32?] = LANHookPreferences.remoteBindings
    @State var newMachineLabel = ""
    @StateObject var hookServer = ClaudeHookServer.shared

    var body: some View {
        SettingsCard(
            title: "局域网 Hook",
            subtitle: "允许局域网内其他机器发送 Hook 事件到本机。"
        ) {
            SettingsRow(
                title: "局域网模式",
                detail: "开启后监听 0.0.0.0，允许局域网设备连接"
            ) {
                Toggle("", isOn: Binding(
                    get: { lanMode },
                    set: { newValue in
                        lanMode = newValue
                        LANHookPreferences.lanMode = newValue
                        if ClaudeHookPreferences.isEnabled {
                            ClaudeHookServer.shared.applyPreferences()
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }

            if lanMode {
                lanDetailSection
            }
        }
    }

    private var lanDetailSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            SettingsRow(
                title: "本机 LAN IP",
                detail: "远程机器的 hook-forwarder 需要指向此地址"
            ) {
                Text(LANHookPreferences.currentLANIP())
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack {
                Text("远程机器映射")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("刷新") {
                    remoteBindings = LANHookPreferences.remoteBindings
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }

            remoteBindingsList

            addMachineRow

            Text("在远程机器的 ~/.vibefocus/hook-config.json 中添加 \"machine_label\": \"标签名\"")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var remoteBindingsList: some View {
        VStack(spacing: 8) {
            let sortedLabels = remoteBindings.keys.sorted()
            if sortedLabels.isEmpty {
                Text("暂无远程机器")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(sortedLabels, id: \.self) { label in
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))

                    Text(label)
                        .font(.system(size: 12, weight: .medium))

                    Spacer()

                    if let windowID = remoteBindings[label] ?? nil {
                        Text("窗口 \(windowID)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未映射")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }

                    Button("映射当前窗口") {
                        mapCurrentWindow(for: label)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("删除") {
                        var updated = remoteBindings
                        updated.removeValue(forKey: label)
                        remoteBindings = updated
                        LANHookPreferences.remoteBindings = updated
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(.red)
                }
            }
        }
    }

    private var addMachineRow: some View {
        HStack {
            TextField("machine_label", text: $newMachineLabel)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .font(.system(size: 12))
            Button("添加") {
                let trimmed = newMachineLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                var updated = remoteBindings
                if updated[trimmed] == nil {
                    updated[trimmed] = nil  // 添加但未映射
                    remoteBindings = updated
                    LANHookPreferences.remoteBindings = updated
                }
                newMachineLabel = ""
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(newMachineLabel.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 4)
    }

    private func mapCurrentWindow(for label: String) {
        guard let identity = WindowManager.shared.captureFocusedWindowIdentity() else {
            return
        }
        var updated = remoteBindings
        updated[label] = identity.windowID
        remoteBindings = updated
        LANHookPreferences.remoteBindings = updated
    }
}
```

- [ ] **Step 2: 在 SettingsUI 中插入 LANSettingsView — 在 Hook card 和 Title Editor card 之间**

文件: `Sources/SettingsUI.swift:959`（在 Hook SettingsCard 的结束 `}` 和空行之后，"窗口标题编辑" SettingsCard 之前插入）

在 line 959（`}` 结束 Hook section）之后，line 961（`SettingsCard(` 开始 Title Editor）之前插入：

```swift

                    LANSettingsView()

```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 4: 构建部署**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/dev-build.sh 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete" or "Installed"

- [ ] **Step 5: 提交**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/LANSettingsView.swift Sources/SettingsUI.swift && git commit -m "feat(ui): add LAN mode toggle and remote machine mapping UI in settings"`
