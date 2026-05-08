# Terminal Window Title Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 让用户能通过全局快捷键编辑当前聚焦终端窗口的标题，解决多终端场景下的窗口辨识问题。

**Architecture:** 用户按下快捷键 → TitleEditorService 获取当前聚焦终端窗口 AXUIElement → 读取窗口当前位置 → 在窗口标题栏下方弹出浮动输入框（TitleEditorPanel） → 用户输入新标题后按 Enter → 双路径设置标题：路径 A 通过 AX API `AXUIElementSetAttributeValue(kAXTitleAttribute)` 设置；路径 B 向窗口对应 TTY 写入 OSC 转义序列 `\033]0;新标题\007` → 输入框自动消失。复用现有 WindowManager 的窗口识别能力（focusedWindow、windowHandle、title），复用 OverlayWindow 的无边框浮动窗口模式。

**Tech Stack:** Swift 5.9, AppKit NSWindow (无边框浮动窗口), Accessibility API (AXUIElementSetAttributeValue), POSIX write() (TTY 转义序列), Carbon HotKey (已有基础设施)

**Risks:**
- Task 1 中 AX API 的 `kAXTitleAttribute` 在 Terminal.app 上可能是 readonly → 缓解：先用 `AXUIElementIsAttributeSettable` 检测，若不可写则 fallback 到 TTY 转义序列方案
- Task 2 中输入框定位依赖窗口 frame 读取，某些终端可能返回不准确的 frame → 缓解：使用 CGWindowList 的 bounds 作为 fallback
- Task 3 中向 TTY 写入转义序列需要窗口对应的 TTY 路径，非 Terminal.app 的终端可能无法获取 → 缓解：TTY 获取失败时仅使用 AX API 路径
- Task 4 中快捷键注册可能与现有 toggle 快捷键冲突 → 缓解：使用独立快捷键 `Ctrl+T`，与现有 `Ctrl+Q` 不冲突

---

### Task 1: 创建 TitleEditorService — 核心标题编辑服务

**Depends on:** None
**Files:**
- Create: `Sources/TitleEditorService.swift`
- Modify: `Sources/WindowManager+AXHelpers.swift:63-70`

- [ ] **Step 1: 创建 TitleEditorService — 负责获取当前窗口、设置标题的双路径逻辑**

```swift
// Sources/TitleEditorService.swift
import AppKit
import ApplicationServices.HIServices
import Foundation

@MainActor
final class TitleEditorService {
    static let shared = TitleEditorService()

    private var editorPanel: TitleEditorPanel?

    private init() {}

    /// 显示标题编辑器：获取当前聚焦终端窗口，在标题栏下方弹出输入框
    func showEditor() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            log("[TitleEditor] No frontmost application", level: .warn)
            return
        }

        let pid = frontApp.processIdentifier

        // 检查是否是终端应用
        let terminalBundleIDs: Set<String> = [
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
        guard terminalBundleIDs.contains(frontApp.bundleIdentifier ?? "") else {
            log("[TitleEditor] Frontmost app is not a terminal: \(frontApp.bundleIdentifier ?? "unknown")", level: .warn)
            return
        }

        guard let window = WindowManager.shared.focusedWindow(for: pid) else {
            log("[TitleEditor] No focused window for pid \(pid)", level: .warn)
            return
        }

        let currentTitle = WindowManager.shared.title(of: window) ?? ""
        let windowFrame = WindowManager.shared.frame(of: window)

        // 关闭已存在的编辑器
        dismissEditor()

        let panel = TitleEditorPanel(
            currentTitle: currentTitle,
            windowFrame: windowFrame,
            onSubmit: { [weak self] newTitle in
                self?.setTitle(newTitle, on: window, pid: pid)
                self?.dismissEditor()
            },
            onCancel: { [weak self] in
                self?.dismissEditor()
            }
        )
        self.editorPanel = panel
        panel.show()
    }

    func dismissEditor() {
        editorPanel?.close()
        editorPanel = nil
    }

    /// 双路径设置标题：AX API + TTY 转义序列
    private func setTitle(_ newTitle: String, on window: AXUIElement, pid: pid_t) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var axSucceeded = false

        // 路径 A: AX API
        if WindowManager.shared.isAttributeSettable(window, attribute: kAXTitleAttribute as String) {
            let titleValue = trimmed as CFString
            let result = AXUIElementSetAttributeValue(window, kAXTitleAttribute as CFString, titleValue)
            if result == .success {
                axSucceeded = true
                log("[TitleEditor] AX API set title succeeded", fields: ["title": trimmed])
            } else {
                log("[TitleEditor] AX API set title failed", level: .warn, fields: ["axStatus": String(result.rawValue)])
            }
        } else {
            log("[TitleEditor] kAXTitleAttribute is not settable, falling back to TTY escape", level: .debug)
        }

        // 路径 B: TTY 转义序列（补充 AX 的不足，或作为 fallback）
        if let tty = resolveTTY(for: pid) {
            sendOSCTitle(trimmed, to: tty)
        } else if !axSucceeded {
            log("[TitleEditor] Both AX and TTY paths failed", level: .error)
        }
    }

    /// 通过 ps 查询终端进程关联的 TTY
    private func resolveTTY(for pid: pid_t) -> String? {
        let output = WindowManager.shared.runShellCommand("/bin/ps", args: ["-o", "tty=", "-p", String(pid)])
        let tty = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tty.isEmpty || tty == "??" || tty == "?" {
            return nil
        }
        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    /// 向 TTY 写入 OSC 转义序列设置终端标题
    /// OSC 格式: ESC ] 0 ; <title> BEL
    private func sendOSCTitle(_ title: String, to ttyPath: String) {
        let escaped = title.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\u{07}", with: "")
        let sequence = "\u{1B}]0;\(escaped)\u{07}"

        guard let fd = open(ttyPath, O_WRONLY | O_NOCTTY), fd >= 0 else {
            log("[TitleEditor] Failed to open TTY for writing", level: .warn, fields: ["tty": ttyPath])
            return
        }
        defer { close(fd) }

        sequence.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }
        log("[TitleEditor] OSC title sent via TTY", fields: ["tty": ttyPath, "title": title])
    }
}
```

- [ ] **Step 2: 给 WindowManager+AXHelpers 添加 runShellCommand 的 public 访问 — 供 TitleEditorService 调用**

文件: `Sources/WindowManager+TerminalContext.swift`（runShellCommand 定义在此文件）

在 `WindowManager` extension 中找到 `runShellCommand` 方法，将其从 `private` 改为 `internal`。需要 grep 确认当前访问级别。

- [ ] **Step 3: 验证 TitleEditorService 编译**
Run: `swift build 2>&1 | head -30`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 4: 提交**
Run: `git add Sources/TitleEditorService.swift && git commit -m "feat(title-editor): add TitleEditorService with AX API and TTY OSC dual-path title setting"`

---

### Task 2: 创建 TitleEditorPanel — 浮动输入框 UI

**Depends on:** Task 1
**Files:**
- Create: `Sources/TitleEditorPanel.swift`

- [ ] **Step 1: 创建 TitleEditorPanel — 在目标窗口标题栏下方弹出的无边框浮动输入框**

```swift
// Sources/TitleEditorPanel.swift
import AppKit

@MainActor
final class TitleEditorPanel: NSPanel {
    private var textField: NSTextField!
    private var onSubmit: ((String) -> Void)?
    private var onCancel: (() -> Void)?

    init(
        currentTitle: String,
        windowFrame: CGRect?,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel

        // 面板尺寸
        let panelWidth: CGFloat = 400
        let panelHeight: CGFloat = 36
        let initialRect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        super.init(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        setupTextField(currentTitle: currentTitle)
        positionPanel(windowFrame: windowFrame, panelWidth: panelWidth)
    }

    private func setupTextField(currentTitle: String) {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 36))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        containerView.layer?.cornerRadius = 6
        containerView.layer?.borderWidth = 1
        containerView.layer?.borderColor = NSColor.selectedControlColor.cgColor

        textField = NSTextField(frame: NSRect(x: 8, y: 4, width: 384, height: 28))
        textField.stringValue = currentTitle
        textField.font = NSFont.systemFont(ofSize: 14)
        textField.drawsBackground = false
        textField.isBordered = false
        textField.focusRingType = .none
        textField.cell?.sendsActionOnEndEditing = false
        textField.delegate = self

        containerView.addSubview(textField)
        self.contentView = containerView
    }

    private func positionPanel(windowFrame: CGRect?, panelWidth: CGFloat) {
        guard let frame = windowFrame else {
            // Fallback: 屏幕中央
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.midX - panelWidth / 2
                let y = screenFrame.maxY - 100
                self.setFrameOrigin(NSPoint(x: x, y: y))
            }
            return
        }

        // 定位在窗口标题栏正下方
        // macOS 坐标系: Y 轴从底部向上
        // 标题栏高度约 28px，窗口 frame.origin.y 是窗口底边
        let titleBarHeight: CGFloat = 28
        let x = frame.origin.x + (frame.width - panelWidth) / 2
        let y = frame.origin.y + frame.height - titleBarHeight - 4

        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show() {
        self.orderFrontRegardless()
        self.makeFirstResponder(textField)

        // 选中全部文本方便直接替换
        DispatchQueue.main.async { [weak self] in
            self?.textField.selectText(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // Return
            onSubmit?(textField.stringValue)
        } else if event.keyCode == 53 { // Escape
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

extension TitleEditorPanel: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onSubmit?(textField.stringValue)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}
```

- [ ] **Step 2: 验证 TitleEditorPanel 编译**
Run: `swift build 2>&1 | head -30`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `git add Sources/TitleEditorPanel.swift && git commit -m "feat(title-editor): add TitleEditorPanel floating input overlay positioned below window title bar"`

---

### Task 3: 注册全局快捷键触发标题编辑

**Depends on:** Task 1, Task 2
**Files:**
- Modify: `Sources/HotKeyManager.swift:88-141`

- [ ] **Step 1: 在 HotKeyManager 中添加标题编辑快捷键注册 — Ctrl+T 触发 TitleEditorService**

文件: `Sources/HotKeyManager.swift`

在现有的 `handleCGEvent` 方法中，检测到 `Ctrl+T` 快捷键时调用 `TitleEditorService.shared.showEditor()`。需要：

1. 添加 `titleEditorKeyCode` 常量（`kVK_ANSI_T = 0x11 = 17`）
2. 在 `handleCGEvent` 中增加 Ctrl+T 的匹配逻辑
3. 匹配成功时吞掉事件并调用 TitleEditorService

在 `handleCGEvent` 方法中，现有快捷键匹配之后，添加标题编辑快捷键检测：

```swift
// 在 handleCGEvent 方法中，现有 toggle 快捷键检测之后添加
// 标题编辑快捷键: Ctrl+T (keyCode 17, modifiers controlKey only)
let titleEditorKeyCode: UInt32 = 17 // kVK_ANSI_T
let titleEditorModifiers: UInt32 = UInt32(controlKey)

if keyCode == titleEditorKeyCode && modifiers == titleEditorModifiers {
    log("[HotKey] Title editor hotkey detected", fields: ["key": "Ctrl+T"])
    DispatchQueue.main.async {
        TitleEditorService.shared.showEditor()
    }
    return Unmanaged.passRetained(event)
}
```

- [ ] **Step 2: 验证快捷键注册编译**
Run: `swift build 2>&1 | head -30`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `git add Sources/HotKeyManager.swift && git commit -m "feat(title-editor): register Ctrl+T global hotkey to trigger title editor"`

---

### Task 4: 设置面板添加标题编辑开关和快捷键配置

**Depends on:** Task 3
**Files:**
- Create: `Sources/TitleEditorPreferences.swift`
- Modify: `Sources/SettingsUI.swift`（在 Claude Hook 设置卡片之后添加新卡片）

- [ ] **Step 1: 创建 TitleEditorPreferences — 管理标题编辑功能的开关和快捷键配置**

```swift
// Sources/TitleEditorPreferences.swift
import Foundation

struct TitleEditorPreferences {
    static let enabledKey = "titleEditorEnabled"
    static let hotKeyEnabledKey = "titleEditorHotKeyEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var isHotKeyEnabled: Bool {
        get {
            if !UserDefaults.standard.object(forKey: hotKeyEnabledKey).exists {
                return true // 默认启用
            }
            return UserDefaults.standard.bool(forKey: hotKeyEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: hotKeyEnabledKey) }
    }
}

// UserDefaults.object(forKey:) 存在性检查辅助
extension Optional where Wrapped == Any {
    var exists: Bool { self != nil }
}
```

- [ ] **Step 2: 在 SettingsView 中添加标题编辑设置卡片 — 开关 + 快捷键说明**

文件: `Sources/SettingsUI.swift`

在 Claude Hook 设置卡片之后添加一个新的 SettingsCard：

```swift
// 在 SettingsView body 中的 Claude Hook card 之后添加
SettingsCard("窗口标题编辑") {
    Toggle("启用标题编辑", isOn: Binding(
        get: { TitleEditorPreferences.isEnabled },
        set: { TitleEditorPreferences.isEnabled = $0 }
    ))
    .font(.system(size: 13))

    Toggle("快捷键 ⌃T", isOn: Binding(
        get: { TitleEditorPreferences.isHotKeyEnabled },
        set: { TitleEditorPreferences.isHotKeyEnabled = $0 }
    ))
    .font(.system(size: 13))

    HStack(spacing: 4) {
        Text("按下")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        Text("⌃T")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15))
            .cornerRadius(3)
        Text("编辑当前终端窗口标题")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 3: 在 HotKeyManager 中检查 TitleEditorPreferences 开关 — 快捷键触发前检查是否启用**

文件: `Sources/HotKeyManager.swift`

在 Task 3 添加的 Ctrl+T 检测代码中，增加 `TitleEditorPreferences.isEnabled` 和 `TitleEditorPreferences.isHotKeyEnabled` 检查：

```swift
if keyCode == titleEditorKeyCode && modifiers == titleEditorModifiers {
    guard TitleEditorPreferences.isEnabled && TitleEditorPreferences.isHotKeyEnabled else {
        return Unmanaged.passRetained(event)
    }
    log("[HotKey] Title editor hotkey detected", fields: ["key": "Ctrl+T"])
    DispatchQueue.main.async {
        TitleEditorService.shared.showEditor()
    }
    return Unmanaged.passRetained(event)
}
```

- [ ] **Step 4: 验证设置面板编译**
Run: `swift build 2>&1 | head -30`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 5: 提交**
Run: `git add Sources/TitleEditorPreferences.swift Sources/SettingsUI.swift Sources/HotKeyManager.swift && git commit -m "feat(title-editor): add settings toggle and preferences for title editor feature"`

---

### Task 5: 完整构建、部署和功能验证

**Depends on:** Task 4
**Files:**
- Modify: 无新文件，端到端验证

- [ ] **Step 1: 完整构建 VibeFocus.app**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 2: 部署并验证功能**

手动验证步骤（构建后执行）：
1. 用完整 app bundle + code signing 部署到 /Applications
2. 打开 Terminal.app，创建 2+ 个终端窗口
3. 点击切换到某个终端窗口，按 `Ctrl+T`
4. 验证：浮动输入框出现在标题栏下方，显示当前窗口标题
5. 输入新标题，按 Enter
6. 验证：终端窗口标题已更新为输入的文本
7. 按 Esc 验证取消功能

- [ ] **Step 3: 最终提交**
Run: `git add -A && git commit -m "feat(title-editor): complete terminal window title editor with Ctrl+T hotkey, AX API + TTY OSC dual-path, and floating input panel"`
