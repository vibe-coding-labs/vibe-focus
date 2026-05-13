# Fix iTerm2 Title Setting: Missing Automation Permission

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 iTerm2 标题设置失败的问题。根因是 Info.plist 缺少 `NSAppleEventsUsageDescription`，导致 macOS 静默拒绝 Apple Event（error -1743），不会弹出权限对话框。同时改进 -1743 错误处理，引导用户授权。

**Architecture:** 用户按 Ctrl+T → TitleEditorService.editTitle() → NSAlert 对话框 → applyTitle() → applyViaAppleScript() 失败（-1743） → TTY 写入被 Claude Code spinner 覆盖。修复：添加 NSAppleEventsUsageDescription 让 macOS 弹出 Automation 权限对话框 + 改进 -1743 错误处理。

**Tech Stack:** Swift 5.9, macOS 13+, NSAppleScript, Info.plist

**Risks:**
- 添加 NSAppleEventsUsageDescription 后首次 AppleScript 调用会触发系统权限对话框 → 缓解：这是正确行为，用户点"允许"即可

---

### Task 1: Add Automation Permission and Improve Error Handling

**Depends on:** None
**Files:**
- Modify: `Info.plist`（添加 NSAppleEventsUsageDescription）
- Modify: `Sources/TitleEditor/TitleEditorService.swift:171-217`（改进 AppleScript 错误处理）

- [ ] **Step 1: 添加 NSAppleEventsUsageDescription 到 Info.plist**

macOS 要求此 key 才会显示 Automation 权限对话框。没有它，Apple Event 被静默拒绝（-1743）。

文件: `Info.plist`（在 `NSAccessibilityUsageDescription` 之后添加）

```xml
<key>NSAppleEventsUsageDescription</key>
<string>VibeFocus 需要 Automation 权限来设置 iTerm2 和 Terminal.app 的窗口标题</string>
```

- [ ] **Step 2: 改进 applyViaAppleScript 错误处理 — 处理 -1743 Automation 权限缺失**

当 AppleScript 因权限缺失失败时（error -1743），显示用户友好的提示并自动打开系统设置。

文件: `Sources/TitleEditor/TitleEditorService.swift:171-217`（替换整个 `applyViaAppleScript` 方法）

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

        if errorNum == -1743 {
            showAutomationPermissionAlert(bundleID: bundleID)
        }
        return false
    }

    log("[TitleEditorService] applyViaAppleScript: success")
    // ... diagnostic readback unchanged ...
```

注意：保留现有的 Terminal.app diagnostic readback 代码不变，只替换错误处理部分。

- [ ] **Step 3: 添加 showAutomationPermissionAlert 方法 — 引导用户授权**

当检测到 -1743 错误时，显示 NSAlert 引导用户到系统设置授权。

文件: `Sources/TitleEditor/TitleEditorService.swift`（在 `applyViaAX` 方法之后添加）

```swift
private func showAutomationPermissionAlert(bundleID: String) {
    let terminalName: String
    switch bundleID {
    case "com.googlecode.iterm2": terminalName = "iTerm2"
    case "com.apple.Terminal": terminalName = "Terminal"
    default: terminalName = "terminal"
    }

    DispatchQueue.main.async {
        let alert = NSAlert()
        alert.messageText = "需要 Automation 权限"
        alert.informativeText = "VibeFocus 需要授权才能修改 \(terminalName) 的窗口标题。\n\n请前往：系统设置 → 隐私与安全性 → Automation → 勾选 VibeFocus 对 \(terminalName) 的控制权限。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        alert.window.level = .floating

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
```

- [ ] **Step 4: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 5: 部署并验证**
Run: `bash scripts/dev-all.sh 2>&1 | tail -10`
Expected:
  - Output contains: "构建成功"
  - Output does NOT contain: "error"

- [ ] **Step 6: 提交**
Run: `git add Info.plist Sources/TitleEditor/TitleEditorService.swift && git commit -m "fix(title-editor): add NSAppleEventsUsageDescription for iTerm2 Automation permission"`
