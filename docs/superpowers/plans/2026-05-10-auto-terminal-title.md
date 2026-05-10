# Auto Terminal Title on Claude Code Session Start

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** Claude Code 启动时自动设置终端窗口标题为项目目录名（如 `vibe-focus — Claude Code`），让多个 Claude Code 实例可通过标题区分，无需手动 Ctrl+T。

**Architecture:** Claude Code SessionStart hook → hook-forwarder 携带 cwd → VibeFocus handleSessionStart → bind 成功后提取项目目录名 → TitleEditorService.autoSetTitle 设置标题（TTY OSC → AppleScript → AX 三路径回退）。复用现有 TitleEditorService 的标题设置基础设施，仅在 HookEventHandler.handleSessionStart 的 bind 成功路径末尾添加一行调用。

**Tech Stack:** Swift 5.9, macOS Accessibility API, OSC escape sequences, AppleScript

**Risks:**
- TTY 设备写入权限不足 → 缓解：TTY OSC 只是三路径之一，AppleScript 和 AX 作为回退
- iTerm2 未授权自动化权限（AppleEvents -1743）→ 缓解：TTY OSC 路径不需要权限
- cwd 可能为 nil → 缓解：用 sessionID 前 8 位作为 fallback 标识

---

### Task 1: Add autoSetTitle method to TitleEditorService

**Depends on:** None
**Files:**
- Modify: `Sources/TitleEditorService.swift:113-145` (applyTitle 方法之后，添加 autoSetTitle)

- [ ] **Step 1: 添加 autoSetTitle 方法 — 接收 cwd 和窗口信息，自动生成并设置标题**

文件: `Sources/TitleEditorService.swift:113`（在 applyTitle 方法之后添加）

```swift
    // MARK: - Auto Title

    func autoSetTitle(cwd: String?, pid: pid_t, bundleID: String, window: AXUIElement) {
        let projectName: String
        if let cwd = cwd, !cwd.isEmpty {
            projectName = URL(fileURLWithPath: cwd).lastPathComponent
        } else {
            projectName = "Claude"
        }
        let title = "\(projectName) — Claude Code"

        log(
            "[TitleEditorService] autoSetTitle",
            fields: [
                "title": title,
                "cwd": cwd ?? "nil",
                "pid": String(pid),
                "bundleID": bundleID
            ]
        )

        applyTitle(title, to: window, pid: pid, bundleID: bundleID)
    }
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

---

### Task 2: Call autoSetTitle on SessionStart bind success

**Depends on:** Task 1
**Files:**
- Modify: `Sources/HookEventHandler.swift:76-93` (handleSessionStart bind 成功后调用 autoSetTitle)

- [ ] **Step 1: 在 handleSessionStart bind 成功后调用 autoSetTitle — 利用已有的窗口信息和 cwd**

文件: `Sources/HookEventHandler.swift:76-93`（替换 bind 调用和 return 语句）

```swift
        let boundWindowID = identity.windowID
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
                fields: ["windowID": String(boundWindowID)]
            )
        }

        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "session_bound",
                message: "Session bound to terminal window via TTY/PPID",
                sessionID: payload.sessionID, handled: true
            )
        )
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 构建并部署 app bundle**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -5 && cp .build/release/VibeFocus /Applications/VibeFocus.app/Contents/MacOS/VibeFocus && codesign --force --deep --sign - /Applications/VibeFocus.app && killall VibeFocus 2>/dev/null; sleep 1; open /Applications/VibeFocus.app`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/TitleEditorService.swift Sources/HookEventHandler.swift && git commit -m "feat(title): auto-set terminal title to project name on Claude Code session start"`
