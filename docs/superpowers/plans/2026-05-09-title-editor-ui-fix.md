# Title Editor UI Fix & Code Split Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复标题编辑器面板无法输入文字的问题，解决 auto-repeat 导致面板反复重建的 bug，并将 TitleEditorService 拆分为更小的文件。

**Architecture:** 两个根因修复：(1) HotKeyManager 中 Ctrl+T 的 auto-repeat 事件未被过滤，每次都触发 editTitle()，导致 panel 刚创建就被销毁重建 → 在 HotKeyManager 添加 auto-repeat 过滤 + TitleEditorService 添加防重复调用守卫；(2) TitleEditorPanel 使用了 `.nonactivatingPanel` styleMask，导致 NSPanel 永远无法成为 key window，NSTextField 无法获取键盘焦点 → 改为 `.titled` + `titlebarAppearsTransparent` + `titleVisibility=.hidden` 的方式，并重写 `canBecomeKey` 返回 true。文件拆分：TTY 写入逻辑提取到 `TitleEditorService+TTYWriter.swift`。

**Tech Stack:** Swift 5.9, AppKit NSPanel, CGEventTap auto-repeat detection

**Risks:**
- `.titled` styleMask 可能显示不需要的标题栏 → 缓解：配合 `titlebarAppearsTransparent=true` + `titleVisibility=.hidden` 隐藏
- 拆分后 extension 文件中的 private 方法需要改为 internal → 缓解：只暴露必要的接口

---

### Task 1: 修复 auto-repeat 导致面板反复重建

**Depends on:** None
**Files:**
- Modify: `Sources/HotKeyManager.swift:220-237`（Ctrl+T 分支）
- Modify: `Sources/TitleEditorService.swift:30-85`（editTitle 方法）

- [ ] **Step 1: 在 HotKeyManager 中为 Ctrl+T 添加 auto-repeat 过滤 — 防止按住 T 键时反复触发**

文件: `Sources/HotKeyManager.swift`

在 `// Title editor hotkey: Ctrl+T` 代码块的开头，添加 auto-repeat 检查。当前 toggle 快捷键在第 156 行已有 auto-repeat 过滤，但 Ctrl+T 分支没有。需要在 `if keyCode == titleEditorKeyCode` 条件内部、guard 之前添加：

```swift
        // Title editor hotkey: Ctrl+T (keyCode 17)
        let titleEditorKeyCode: UInt32 = 17
        let titleEditorModifiers: UInt32 = UInt32(controlKey)
        if keyCode == titleEditorKeyCode && modifiers == titleEditorModifiers {
            // Ignore auto-repeat — only act on the initial key press
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil // Consume but don't act
            }

            let enabled = TitleEditorPreferences.isEnabled
            let hotKeyEnabled = TitleEditorPreferences.isHotKeyEnabled
            log(
                "[HotKey] Title editor Ctrl+T matched",
                level: .debug,
                fields: [
                    "isEnabled": String(enabled),
                    "isHotKeyEnabled": String(hotKeyEnabled)
                ]
            )
            guard enabled && hotKeyEnabled else {
                log("[HotKey] Title editor disabled, passing event through", level: .warn)
                return Unmanaged.passUnretained(event)
            }
            log("[HotKey] Title editor hotkey detected", fields: ["key": "Ctrl+T"])
            DispatchQueue.main.async {
                TitleEditorService.shared.editTitle()
            }
            return nil
        }
```

- [ ] **Step 2: 在 TitleEditorService.editTitle() 中添加防重复调用守卫 — 已有 activePanel 时不重复创建**

文件: `Sources/TitleEditorService.swift:30-85`

替换 `editTitle()` 方法，在方法开头添加守卫：

```swift
    func editTitle() {
        // 如果已有活跃面板，不重复创建
        guard activePanel == nil else {
            log("[TitleEditorService] editTitle: panel already active, ignoring")
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
        let windowFrame = WindowManager.shared.frame(of: window)

        log(
            "[TitleEditorService] editTitle: showing editor",
            fields: [
                "bundleID": bundleID,
                "currentTitle": truncateForLog(currentTitle, limit: 60),
                "pid": String(pid)
            ]
        )

        let panel = TitleEditorPanel(
            currentTitle: currentTitle,
            windowFrame: windowFrame,
            onSubmit: { [weak self] newTitle in
                self?.applyTitle(newTitle, to: window, pid: pid, bundleID: bundleID)
                self?.activePanel = nil
            },
            onCancel: { [weak self] in
                self?.activePanel = nil
            }
        )

        activePanel = panel
        panel.show()
    }
```

- [ ] **Step 3: 验证编译**
Run: `swift build 2>&1 | grep -i "error:" | head -5`
Expected:
  - Exit code: 0
  - Output is empty (no errors)

- [ ] **Step 4: 提交**
Run: `git add Sources/HotKeyManager.swift Sources/TitleEditorService.swift && git commit -m "fix(title-editor): prevent auto-repeat from recreating panel and add duplicate-call guard"`

---

### Task 2: 修复面板无法获取键盘焦点 — 可以输入文字

**Depends on:** Task 1
**Files:**
- Modify: `Sources/TitleEditorPanel.swift:1-116`

- [ ] **Step 1: 重写 TitleEditorPanel — 修复 key window 和焦点问题**

文件: `Sources/TitleEditorPanel.swift`（替换整个文件）

核心修改：
1. styleMask 从 `.borderless, .nonactivatingPanel` 改为 `.titled, .fullSizeContentView`
2. 添加 `canBecomeKey` 重写返回 true
3. 隐藏标题栏但保留可成为 key window 的能力
4. 使用 NSTextField 的编辑器模式确保可以输入

```swift
import AppKit

// MARK: - Title Editor Panel
// 浮动输入框，定位在目标终端窗口标题栏下方
@MainActor
class TitleEditorPanel: NSPanel {
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void
    private var textField: NSTextField!

    init(
        currentTitle: String,
        windowFrame: CGRect?,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel

        let panelWidth: CGFloat = 420
        let panelHeight: CGFloat = 40
        var origin: CGPoint
        if let frame = windowFrame {
            let titleBarHeight: CGFloat = 28
            origin = CGPoint(
                x: frame.midX - panelWidth / 2,
                y: frame.maxY - titleBarHeight - panelHeight - 4
            )
        } else if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            origin = CGPoint(
                x: screenFrame.midX - panelWidth / 2,
                y: screenFrame.maxY - 100
            )
        } else {
            origin = CGPoint(x: 100, y: 100)
        }

        let rect = NSRect(x: origin.x, y: origin.y, width: panelWidth, height: panelHeight)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = false
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true

        setupContent(currentTitle: currentTitle, panelWidth: panelWidth, panelHeight: panelHeight)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func setupContent(currentTitle: String, panelWidth: CGFloat, panelHeight: CGFloat) {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        containerView.layer?.cornerRadius = 8
        containerView.layer?.borderWidth = 1.5
        containerView.layer?.borderColor = NSColor.selectedControlColor.cgColor

        textField = NSTextField(frame: NSRect(x: 10, y: 5, width: panelWidth - 20, height: panelHeight - 10))
        textField.stringValue = currentTitle
        textField.font = NSFont.systemFont(ofSize: 14)
        textField.drawsBackground = false
        textField.isBordered = false
        textField.focusRingType = .none
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.cell?.sendsActionOnEndEditing = false
        textField.delegate = self

        containerView.addSubview(textField)
        self.contentView = containerView
    }

    func show() {
        self.orderFrontRegardless()
        self.makeKey()
        self.makeFirstResponder(textField)
        DispatchQueue.main.async { [weak self] in
            guard let self, let textField = self.textField else { return }
            self.makeFirstResponder(textField)
            textField.selectText(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // Return
            onSubmit(textField.stringValue)
            close()
        } else if event.keyCode == 53 { // Escape
            onCancel()
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

extension TitleEditorPanel: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onSubmit(textField.stringValue)
            close()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel()
            close()
            return true
        }
        return false
    }
}
```

- [ ] **Step 2: 验证编译**
Run: `swift build 2>&1 | grep -i "error:" | head -5`
Expected:
  - Exit code: 0
  - Output is empty (no errors)

- [ ] **Step 3: 构建部署并测试**
Run: `bash scripts/dev-build.sh 2>&1 | tail -5`
Expected:
  - Output contains: "构建成功"
  - 退出码：0

- [ ] **Step 4: 提交**
Run: `git add Sources/TitleEditorPanel.swift && git commit -m "fix(title-editor): fix panel unable to receive keyboard input — use titled styleMask with canBecomeKey=true"`

---

### Task 3: 拆分 TitleEditorService — TTY 写入逻辑提取到独立文件

**Depends on:** Task 2
**Files:**
- Create: `Sources/TitleEditorService+TTYWriter.swift`
- Modify: `Sources/TitleEditorService.swift:135-192`（移除 TTY 相关代码）

- [ ] **Step 1: 创建 TitleEditorService+TTYWriter.swift — 提取 TTY 解析和 OSC 序列写入**

```swift
import Darwin
import Foundation

// MARK: - Title Editor TTY Writer
// 通过 TTY 设备写入 OSC 转义序列设置终端窗口标题
@MainActor
extension TitleEditorService {

    /// Path B: Write OSC escape sequence to the terminal's TTY device
    func applyViaTTY(_ title: String, pid: pid_t) -> Bool {
        guard let ttyPath = resolveTTYPath(for: pid) else {
            log(
                "[TitleEditorService] applyViaTTY: could not resolve TTY",
                level: .debug,
                fields: ["pid": String(pid)]
            )
            return false
        }

        let sequence = "\u{1B}]0;\(title)\u{07}"
        return writeTTYSequence(sequence, to: ttyPath)
    }

    func resolveTTYPath(for pid: pid_t) -> String? {
        let output = WindowManager.shared.runShellCommand("/bin/ps", args: ["-o", "tty=", "-p", String(pid)])
        let tty = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if tty.isEmpty || tty == "??" || tty == "?" {
            return nil
        }

        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    func writeTTYSequence(_ sequence: String, to ttyPath: String) -> Bool {
        guard let data = sequence.data(using: .utf8) else { return false }

        let fd = open(ttyPath, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else {
            log(
                "[TitleEditorService] writeTTYSequence: open() failed",
                level: .warn,
                fields: ["ttyPath": ttyPath, "errno": String(errno)]
            )
            return false
        }
        defer { close(fd) }

        let written = data.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, ptr.count)
        }

        let success = written >= 0
        if !success {
            log(
                "[TitleEditorService] writeTTYSequence: write() failed",
                level: .warn,
                fields: ["ttyPath": ttyPath, "errno": String(errno)]
            )
        }
        return success
    }
}
```

- [ ] **Step 2: 从 TitleEditorService.swift 中移除已提取的 TTY 代码 — 只保留核心逻辑**

文件: `Sources/TitleEditorService.swift`

删除以下三个方法（已移到 extension 文件）：
- `applyViaTTY(_:pid:)` (约 line 136-148)
- `resolveTTYPath(for:)` (约 line 152-161)
- `writeTTYSequence(_:to:)` (约 line 165-192)

同时删除 `import Darwin`（不再需要，TTYWriter 文件自己 import）。

- [ ] **Step 3: 验证编译**
Run: `swift build 2>&1 | grep -i "error:" | head -5`
Expected:
  - Exit code: 0
  - Output is empty (no errors)

- [ ] **Step 4: 构建部署**
Run: `bash scripts/dev-build.sh 2>&1 | tail -5`
Expected:
  - Output contains: "构建成功"

- [ ] **Step 5: 提交**
Run: `git add Sources/TitleEditorService.swift Sources/TitleEditorService+TTYWriter.swift && git commit -m "refactor(title-editor): extract TTY writer logic into separate extension file"`
