# Title Editor Two Bug Fixes Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复两个 bug：(1) 终端标题只部分替换（`set custom title` 只设置一个组件，`title displays window size` 仍然显示 "233×69"）；(2) Ctrl+T 弹窗关闭后 VibeFocus 设置窗口自动弹出（`NSApp.activate` 导致 VibeFocus 可见）。

**Root Cause 1:** Terminal.app 的标题由多个组件组成：OSC 运行标题 + custom title + window size + 其他。当前 AppleScript 的 `set custom title` 只设置了一个组件，`title displays window size: true` 仍追加 "233×69"。同时 TTY OSC 设置了完整标题，但随后的 AppleScript 导致 Terminal.app 重建标题覆盖了 OSC 结果。

**Root Cause 2:** `NSApp.activate(ignoringOtherApps: true)` 在弹窗前激活 VibeFocus 使其成为前台应用。`runModal()` 关闭后 VibeFocus 仍为前台应用，设置窗口（VibeFocus 唯一窗口）变为可见。

**Architecture:** 两个独立修复：(1) 调整 `applyTitle` 调用顺序为 AppleScript → TTY（TTY 的完整标题覆盖 AppleScript 的部分效果），并更新 Terminal.app 的 AppleScript 同时配置 `title displays *` 属性禁用除 custom title 外的所有组件。(2) 在 `alert.runModal()` 关闭后调用 `frontApp.activate(options:)` 将焦点还给终端应用。

**Tech Stack:** Swift 5.9, AppKit NSAlert, NSAppleScript, NSRunningApplication, macOS 13.0+

**Risks:**
- Terminal.app `title displays *` 属性修改 profile 配置，影响同 profile 所有窗口 → 可接受：用户明确要求完整替换标题
- Claude Code 的 spinner 会持续通过 OSC 覆盖运行标题 → 缓解：配置只显示 custom title 组件，custom title 不受 OSC 影响
- `frontApp` 在 modal 期间可能失效 → 缓解：`NSRunningApplication` 是强引用，只要进程存在就有效

---

### Task 1: Fix terminal title only partially replaced

**Depends on:** None
**Files:**
- Modify: `Sources/TitleEditorService.swift:109-130`（重写 `applyTitle` 调用顺序）
- Modify: `Sources/TitleEditorService.swift:132-171`（重写 `applyViaAppleScript` Terminal.app case）

- [ ] **Step 1: 修改 `applyTitle` 调用顺序 — AppleScript 先于 TTY 执行**

文件: `Sources/TitleEditorService.swift:109-130`（替换整个 `applyTitle` 方法）

```swift
    private func applyTitle(_ newTitle: String, to window: AXUIElement, pid: pid_t, bundleID: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log("[TitleEditorService] applyTitle: empty title, skipping")
            return
        }

        let axSuccess = applyViaAX(trimmed, to: window)
        // AppleScript first: configures Terminal.app title display settings
        // then TTY overrides with full title via OSC escape sequence
        let scriptSuccess = applyViaAppleScript(trimmed, bundleID: bundleID)
        let ttySuccess = applyViaTTY(trimmed, pid: pid)

        log(
            "[TitleEditorService] applyTitle result",
            fields: [
                "title": truncateForLog(trimmed, limit: 60),
                "axSuccess": String(axSuccess),
                "ttySuccess": String(ttySuccess),
                "scriptSuccess": String(scriptSuccess),
                "bundleID": bundleID
            ]
        )
    }
```

- [ ] **Step 2: 更新 `applyViaAppleScript` — Terminal.app 同时配置标题显示设置**

文件: `Sources/TitleEditorService.swift:132-171`（替换整个 `applyViaAppleScript` 方法）

```swift
    private func applyViaAppleScript(_ title: String, bundleID: String) -> Bool {
        let script: String
        switch bundleID {
        case "com.apple.Terminal":
            let escaped = title
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script = """
                tell application "Terminal"
                    set custom title of selected tab of front window to "\(escaped)"
                    tell current settings of front window
                        set title displays custom title to true
                        set title displays device name to false
                        set title displays shell path to false
                        set title displays window size to false
                        set title displays settings name to false
                    end tell
                end tell
                """
        case "com.googlecode.iterm2":
            let escaped = title
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script = "tell application \"iTerm2\" to set name of current session of current window to \"\(escaped)\""
        default:
            return false
        }

        log(
            "[TitleEditorService] applyViaAppleScript: setting title",
            fields: ["bundleID": bundleID, "title": truncateForLog(title, limit: 60)]
        )

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)

        if let error {
            let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            let errorNum = error[NSAppleScript.errorNumber] as? Int ?? -1
            log(
                "[TitleEditorService] applyViaAppleScript: FAILED",
                level: .warn,
                fields: ["errorMsg": errorMsg, "errorNum": String(errorNum)]
            )
            return false
        }

        log("[TitleEditorService] applyViaAppleScript: success")
        return true
    }
```

- [ ] **Step 3: 验证编译**

Run: `bash scripts/dev-build.sh`

Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 4: 提交**

Run: `git add Sources/TitleEditorService.swift && git commit -m "fix(title-editor): configure Terminal.app title display and reorder apply methods"`

---

### Task 2: Fix settings window popping up after Ctrl+T

**Depends on:** None
**Files:**
- Modify: `Sources/TitleEditorService.swift:96-104`（modal 关闭后重新激活终端）

- [ ] **Step 1: 在 `alert.runModal()` 关闭后重新激活终端应用**

文件: `Sources/TitleEditorService.swift:96-105`（替换 `runModal()` 之后的代码块）

```swift
        let response = alert.runModal()
        isEditing = false

        // Reactivate terminal app to prevent VibeFocus settings window from appearing
        _ = frontApp.activate(options: .activateIgnoringOtherApps)

        if response == .alertFirstButtonReturn {
            let newTitle = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newTitle.isEmpty {
                applyTitle(newTitle, to: window, pid: pid, bundleID: bundleID)
            }
        }
```

- [ ] **Step 2: 验证编译**

Run: `bash scripts/dev-build.sh`

Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**

Run: `git add Sources/TitleEditorService.swift && git commit -m "fix(title-editor): reactivate terminal after dialog to prevent settings window"`

---

### Task 3: Build, deploy, and smoke test

**Depends on:** Task 1, Task 2
**Files:**
- No file changes

- [ ] **Step 1: 全量构建并部署**

Run: `bash scripts/dev-build.sh`

Expected:
  - Exit code: 0
  - Output contains: "signed" or "verified"

- [ ] **Step 2: 重启 VibeFocus**

Run: `pkill -9 -f "VibeFocus" && sleep 1 && open /Applications/VibeFocus.app`

Expected:
  - Exit code: 0
  - New VibeFocus process running from `/Applications/VibeFocus.app`

- [ ] **Step 3: 验证进程运行**

Run: `pgrep -lf VibeFocus`

Expected:
  - Exit code: 0
  - Output contains: "VibeFocus" with a PID
