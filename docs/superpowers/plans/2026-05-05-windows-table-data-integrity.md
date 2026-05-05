# Windows 表数据完整性修复 — 补全 cwd/model 存储 + 窗口关闭清理

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 `windows` SQLite 表中 `cwd`（项目路径）和 `model`（AI 模型）字段始终为 NULL 的问题，并添加窗口关闭后的记录清理机制。

**Architecture:** ClaudeHookPayload 已正确解码 `cwd` 和 `model`，但 `SessionWindowRegistry.bind()` 不接收这两个参数 → 修改 bind() 签名传递数据 → 自动持久化到 SQLite。窗口关闭检测：在 SessionWindowRegistry 新增 `purgeClosedWindows()` 方法，遍历内存中所有 active 绑定，通过 CGWindowList 验证窗口是否仍存在，不存在则删除记录。由定时器每 60 秒触发一次。

**Tech Stack:** Swift 5.9, macOS 13+, SQLite3, CGWindowList API

**Risks:**
- Task 1 修改 `bind()` 方法签名，需确认所有调用点 — 缓解：全局搜索只有 HookEventHandler.handleSessionStart 一个调用点
- Task 2 的 CGWindowList 轮询需控制频率 — 缓解：60 秒间隔 + 仅检查 active 绑定
- Task 3 部署需完整 app bundle — 缓解：严格使用 `bash scripts/dev-build.sh`

---

### Task 1: 补全 cwd 和 model 字段传递链

**Depends on:** None
**Files:**
- Modify: `Sources/SessionWindowRegistry.swift:35-72`（bind 方法）
- Modify: `Sources/HookEventHandler.swift:76-81`（bind 调用点）

- [ ] **Step 1: 修改 SessionWindowRegistry.bind() 签名以接收 cwd 和 model 参数**
文件: `Sources/SessionWindowRegistry.swift:35`（替换 bind 方法签名和实现）

```swift
// 替换 Sources/SessionWindowRegistry.swift:35-72 的 bind 方法
// 将签名从：
//   func bind(sessionID: String, windowIdentity: WindowIdentity, terminalTTY: String? = nil, terminalSessionID: String? = nil)
// 改为：
    func bind(sessionID: String, windowIdentity: WindowIdentity, terminalTTY: String? = nil, terminalSessionID: String? = nil, cwd: String? = nil, model: String? = nil) {
        let now = Date()
        let key = cacheKey(pid: windowIdentity.pid, tty: terminalTTY)

        if var existing = windowStates[key] {
            existing.windowID = windowIdentity.windowID
            existing.axWindowNumber = windowIdentity.windowNumber
            existing.appName = windowIdentity.appName
            existing.bundleIdentifier = windowIdentity.bundleIdentifier
            existing.title = windowIdentity.title
            existing.sessionID = sessionID
            existing.isCompleted = false
            existing.completedAt = nil
            existing.updatedAt = now
            existing.tty = terminalTTY
            existing.termSessionID = terminalSessionID
            existing.cwd = cwd
            existing.model = model
            windowStates[key] = existing
        } else {
            var state = WindowState(
                pid: windowIdentity.pid,
                tty: terminalTTY,
                windowID: windowIdentity.windowID,
                axWindowNumber: windowIdentity.windowNumber,
                appName: windowIdentity.appName,
                bundleIdentifier: windowIdentity.bundleIdentifier,
                title: windowIdentity.title,
                termSessionID: terminalSessionID,
                sessionID: sessionID,
                isCompleted: false,
                createdAt: now,
                updatedAt: now
            )
            state.cwd = cwd
            state.model = model
            windowStates[key] = state
        }

        lastEventDescription = "SessionStart 绑定窗口：\(windowIdentity.appName ?? "Unknown") / \(windowIdentity.title ?? "Untitled")"
        pruneExpiredBindings(shouldPersist: false)
        persistToDB(key: key)
    }
```

- [ ] **Step 2: 修改 HookEventHandler.handleSessionStart 调用点传递 cwd 和 model**
文件: `Sources/HookEventHandler.swift:76-81`（替换 bind 调用）

```swift
// 替换 Sources/HookEventHandler.swift:76-81 的 bind 调用
        SessionWindowRegistry.shared.bind(
            sessionID: payload.sessionID,
            windowIdentity: identity,
            terminalTTY: payload.terminalCtx?.tty,
            terminalSessionID: payload.terminalCtx?.termSessionID ?? payload.terminalCtx?.itermSessionID,
            cwd: payload.cwd,
            model: payload.model
        )
```

- [ ] **Step 3: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:" or "cannot find"

- [ ] **Step 4: 提交**
Run: `git add Sources/SessionWindowRegistry.swift Sources/HookEventHandler.swift && git commit -m "fix(data): pass cwd and model to SessionWindowRegistry.bind() for SQLite storage"`

---

### Task 2: 添加窗口关闭检测与记录清理

**Depends on:** Task 1
**Files:**
- Modify: `Sources/SessionWindowRegistry.swift`（新增 purgeClosedWindows 方法）
- Modify: `Sources/SettingsUI.swift:2268`（AppDelegate.applicationDidFinishLaunching 注册定时器）

- [ ] **Step 1: 在 SessionWindowRegistry 新增 purgeClosedWindows 方法**
文件: `Sources/SessionWindowRegistry.swift`（在 `clearAllBindings()` 方法之后、`// MARK: - UI Support` 之前插入）

```swift
// 在 Sources/SessionWindowRegistry.swift 的 clearAllBindings() 之后（约 254 行后）插入

    /// 检查并清理已关闭窗口的记录
    /// 遍历所有 active 绑定，通过 CGWindowList 验证窗口是否仍存在
    func purgeClosedWindows() {
        let options: CGWindowListOption = [.optionAll]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        // 构建 pid → windowIDs 映射
        var pidWindows: [Int32: Set<UInt32>] = [:]
        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let wid = info[kCGWindowNumber as String] as? UInt32 else { continue }
            pidWindows[pid, default: []].insert(wid)
        }

        var purgedCount = 0
        let keysToRemove = windowStates.filter { key, state in
            guard !state.isCompleted else { return false }
            guard let wid = state.windowID else { return false }
            // PID 不存在 或 windowID 不在 CGWindowList 中
            let pidExists = pidWindows[state.pid] != nil
            if !pidExists { return true }
            let widExists = pidWindows[state.pid]?.contains(wid) ?? false
            return !widExists
        }.map(\.key)

        for key in keysToRemove {
            let state = windowStates[key]
            log("[SessionWindowRegistry] purging closed window: pid=\(windowStates[key]?.pid ?? 0) tty=\(windowStates[key]?.tty ?? "") app=\(windowStates[key]?.appName ?? "unknown")")
            windowStates.removeValue(forKey: key)
            if let state {
                WindowStateStore.shared.deleteWindowState(pid: state.pid, tty: state.tty)
            }
            purgedCount += 1
        }

        if purgedCount > 0 {
            log("[SessionWindowRegistry] purgeClosedWindows removed \(purgedCount) stale records")
        }
    }
```

- [ ] **Step 2: 在 AppDelegate.applicationDidFinishLaunching 注册 60 秒定时器**
文件: `Sources/SettingsUI.swift:2268`（在 `promptAccessibilityIfNeeded()` 之后添加）

```swift
// 在 Sources/SettingsUI.swift:2268 的 promptAccessibilityIfNeeded() 之后添加
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                SessionWindowRegistry.shared.purgeClosedWindows()
            }
        }
```

- [ ] **Step 3: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:" or "cannot find"

- [ ] **Step 4: 提交**
Run: `git add Sources/SessionWindowRegistry.swift Sources/SettingsUI.swift && git commit -m "feat(cleanup): add purgeClosedWindows to detect and remove stale window records"`

---

### Task 3: 部署并验证数据完整性

**Depends on:** Task 2
**Files:**
- Modify: 无代码修改
- Verify: `~/.vibefocus/vibefocus.db`

- [ ] **Step 1: 部署到 /Applications/VibeFocus.app**
Run: `bash scripts/dev-build.sh 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "signed" or "installed"

- [ ] **Step 2: 触发一次 SessionStart 事件（通过 Claude Code 重新启动会话）**

手动操作：重启当前 Claude Code 会话，使其发送 SessionStart hook，观察 cwd 和 model 是否被存储。

- [ ] **Step 3: 验证 windows 表中 cwd 和 model 字段已填充**
Run: `sqlite3 -header ~/.vibefocus/vibefocus.db "SELECT pid, tty, session_id, cwd, model, window_id, app_name FROM windows ORDER BY updated_at DESC LIMIT 5;"`
Expected:
  - Output contains: project directory path (e.g., "/Users/cc11001100/github/vibe-coding-labs/vibe-focus")
  - Output contains: model name (e.g., "claude-sonnet" or similar)
  - cwd is NOT empty/NULL

- [ ] **Step 4: 验证窗口关闭清理逻辑（关闭终端窗口后等待 60 秒）**

手动操作：关闭一个已绑定的终端窗口，等待 60 秒让 purgeClosedWindows 触发，然后检查数据库记录是否被删除。

Run: `sqlite3 -header ~/.vibefocus/vibefocus.db "SELECT COUNT(*) as total FROM windows;"`
Expected:
  - 已关闭窗口的记录已被删除
  - total 小于关闭前的记录数

- [ ] **Step 5: 提交验证结果**

记录验证通过的截图或输出。
