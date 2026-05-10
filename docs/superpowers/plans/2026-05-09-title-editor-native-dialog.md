# Title Editor Native Dialog Rewrite Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 用原生 NSAlert 弹窗替换当前自定义 NSPanel 实现，解决快捷键时灵时不灵和输入框无法交互的问题。弹窗居中显示（黄金比例偏上），用户输入标题后按回车即可设置。

**Architecture:** Ctrl+T 热键触发 → HotKeyManager 检测 → DispatchQueue.main.async 调度到主线程 → TitleEditorService.editTitle() 检测前台终端窗口 → 创建 NSAlert + NSTextField accessoryView → runModal() 阻塞等待用户输入 → 用户按 OK/Enter → 通过 AX API + TTY OSC 转义序列双路径设置标题。删除自定义 TitleEditorPanel 类，NSAlert 代码内联到 TitleEditorService。

**Tech Stack:** Swift 5.9, AppKit NSAlert, macOS 13.0+, AX API, TTY OSC escape sequences

**Risks:**
- NSAlert.runModal() 阻塞主线程期间其他异步任务无法执行 → 可接受：标题编辑是短暂用户交互（<10秒）
- LSUIElement 背景应用中 NSAlert 可能不获得焦点 → 缓解：NSApp.activate(ignoringOtherApps: true) + alert.window.level = .floating
- Fallback handler 缺少 Ctrl+T 支持，CGEvent tap 被禁用时标题编辑完全失效 → 缓解：Task 2 补充 fallback handler

---

### Task 1: Replace TitleEditorPanel with NSAlert in TitleEditorService

**Depends on:** None
**Files:**
- Modify: `Sources/TitleEditorService.swift:1-139`（重写整个文件，用 NSAlert 替换 NSPanel 调用）
- Delete: `Sources/TitleEditorPanel.swift`（不再需要自定义 Panel 类）

- [ ] **Step 1: 重写 TitleEditorService.swift — 用原生 NSAlert 替换自定义 NSPanel**

```swift
// Sources/TitleEditorService.swift — 完整替换
import AppKit
import ApplicationServices.HIServices
import Foundation

@MainActor
class TitleEditorService {
    static let shared = TitleEditorService()

    private let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.electron.hyper",
        "org.tabby"
    ]

    private var isEditing = false

    // MARK: - Public API

    func editTitle() {
        guard !isEditing else {
            log("[TitleEditorService] editTitle: already editing, ignoring")
            return
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            log("[TitleEditorService] editTitle: no frontmost application")
            return
        }

        let bundleID = frontApp.bundleIdentifier ?? ""
        guard terminalBundleIDs.contains(bundleID) else {
            log(
                "[TitleEditorService] editTitle: frontmost app is not a recognized terminal",
                level: .debug,
                fields: ["bundleID": bundleID]
            )
            return
        }

        let pid = frontApp.processIdentifier
        guard let window = WindowManager.shared.focusedWindow(for: pid) else {
            log(
                "[TitleEditorService] editTitle: could not get focused window",
                level: .warn,
                fields: ["pid": String(pid), "bundleID": bundleID]
            )
            return
        }

        let currentTitle = WindowManager.shared.title(of: window) ?? ""

        log(
            "[TitleEditorService] editTitle: showing native alert",
            fields: [
                "bundleID": bundleID,
                "currentTitle": truncateForLog(currentTitle, limit: 60),
                "pid": String(pid)
            ]
        )

        isEditing = true

        // Activate app to ensure alert gets focus (LSUIElement background app)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Edit Terminal Title"
        alert.informativeText = "Enter the new title for the terminal window"
        alert.alertStyle = .informational

        let inputField = NSTextField(string: currentTitle)
        inputField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        inputField.selectsAll = true
        inputField.font = NSFont.systemFont(ofSize: 13)
        alert.accessoryView = inputField

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        // Position: centered with golden ratio vertical offset
        alert.window.center()
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let goldenY = visibleFrame.origin.y + visibleFrame.height * 0.618
            var frame = alert.window.frame
            frame.origin.y = goldenY - frame.height / 2
            alert.window.setFrame(frame, display: true)
        }

        alert.window.level = .floating

        let response = alert.runModal()
        isEditing = false

        if response == .alertFirstButtonReturn {
            let newTitle = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newTitle.isEmpty {
                applyTitle(newTitle, to: window, pid: pid, bundleID: bundleID)
            }
        }
    }

    // MARK: - Title Application

    private func applyTitle(_ newTitle: String, to window: AXUIElement, pid: pid_t, bundleID: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log("[TitleEditorService] applyTitle: empty title, skipping")
            return
        }

        let axSuccess = applyViaAX(trimmed, to: window)
        let ttySuccess = applyViaTTY(trimmed, pid: pid)

        log(
            "[TitleEditorService] applyTitle result",
            fields: [
                "title": truncateForLog(trimmed, limit: 60),
                "axSuccess": String(axSuccess),
                "ttySuccess": String(ttySuccess),
                "bundleID": bundleID
            ]
        )
    }

    private func applyViaAX(_ title: String, to window: AXUIElement) -> Bool {
        guard WindowManager.shared.isAttributeSettable(window, attribute: kAXTitleAttribute as String) else {
            log(
                "[TitleEditorService] applyViaAX: kAXTitleAttribute not settable",
                level: .debug
            )
            return false
        }

        let result = AXUIElementSetAttributeValue(window, kAXTitleAttribute as CFString, title as CFTypeRef)
        let success = result == .success
        if !success {
            log(
                "[TitleEditorService] applyViaAX: AXUIElementSetAttributeValue failed",
                level: .warn,
                fields: ["axStatus": String(result.rawValue)]
            )
        }
        return success
    }
}
```

- [ ] **Step 2: 删除 TitleEditorPanel.swift — NSAlert 内联到 Service 后不再需要自定义 Panel**

Run: `rm Sources/TitleEditorPanel.swift`

Expected:
  - Exit code: 0
  - File `Sources/TitleEditorPanel.swift` no longer exists

- [ ] **Step 3: 验证编译**
Run: `bash scripts/dev-build.sh`
Expected:
  - Exit code: 0
  - Output contains: "Build complete" or "_codesign"
  - Output does NOT contain: "error:" or "undefined" or "cannot find type"

- [ ] **Step 4: 提交**
Run: `git add Sources/TitleEditorService.swift && git rm Sources/TitleEditorPanel.swift && git commit -m "fix(title-editor): replace custom NSPanel with native NSAlert dialog"`

---

### Task 2: Add Ctrl+T support to fallback event handler

**Depends on:** Task 1
**Files:**
- Modify: `Sources/HotKeyManager.swift:419-454`（在 handleFallbackEvent 中添加 Ctrl+T 处理）

- [ ] **Step 1: 修改 handleFallbackEvent 以支持 Ctrl+T 标题编辑器热键**

文件: `Sources/HotKeyManager.swift:419-454`（替换整个 handleFallbackEvent 函数）

```swift
// 替换 Sources/HotKeyManager.swift:419-454 的 handleFallbackEvent 函数
private func handleFallbackEvent(_ event: NSEvent, source: String) -> Bool {
    if event.isARepeat {
        return false
    }

    let eventKeyCode = UInt32(event.keyCode)
    let eventModifiers = event.modifierFlags.intersection(.hotKeyRelevantFlags).carbonHotKeyModifiers
    let matches = currentHotKey.matches(event: event)

    log(
        "[HotKey] handleFallbackEvent",
        level: .debug,
        fields: [
            "source": source,
            "keyCode": String(eventKeyCode),
            "modifiers": String(eventModifiers),
            "expectedKeyCode": String(currentHotKey.keyCode),
            "expectedModifiers": String(currentHotKey.modifiers),
            "matches": String(matches)
        ]
    )

    // Main toggle hotkey
    guard matches else {
        // Check for title editor hotkey: Ctrl+T (keyCode 17)
        let titleEditorKeyCode: UInt32 = 17
        let titleEditorModifiers: UInt32 = UInt32(controlKey)
        if eventKeyCode == titleEditorKeyCode && eventModifiers == titleEditorModifiers {
            let enabled = TitleEditorPreferences.isEnabled
            let hotKeyEnabled = TitleEditorPreferences.isHotKeyEnabled
            guard enabled && hotKeyEnabled else { return false }
            log("[HotKey] Title editor Ctrl+T matched in fallback handler")
            DispatchQueue.main.async {
                TitleEditorService.shared.editTitle()
            }
            return true
        }
        return false
    }

    log("Fallback hotkey \(currentHotKey.displayString) triggered from \(source)")
    triggerToggleIfNeeded(source: "fallback_\(source)")
    return true
}
```

- [ ] **Step 2: 验证编译**
Run: `bash scripts/dev-build.sh`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `git add Sources/HotKeyManager.swift && git commit -m "fix(hotkey): add Ctrl+T title editor support to fallback event handler"`

---

### Task 3: Build, deploy, and smoke test

**Depends on:** Task 2
**Files:**
- No file changes — build and deploy only

- [ ] **Step 1: 全量构建并部署**
Run: `bash scripts/dev-build.sh`
Expected:
  - Exit code: 0
  - Output contains: "signed" or "verified"
  - App deployed to `/Applications/VibeFocus.app`

- [ ] **Step 2: 重启 VibeFocus 进程**
Run: `pkill -9 -f "VibeFocus" && sleep 1 && open /Applications/VibeFocus.app`
Expected:
  - Exit code: 0
  - New VibeFocus process is running

- [ ] **Step 3: 验证进程运行**
Run: `pgrep -lf VibeFocus`
Expected:
  - Exit code: 0
  - Output contains: "VibeFocus" with a PID
