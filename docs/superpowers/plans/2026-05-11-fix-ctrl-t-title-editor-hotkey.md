# Fix Ctrl+T Title Editor Hotkey Not Working

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 Ctrl+T 快捷键无法触发终端窗口标题编辑器的问题。日志显示 CGEventTap 检测到 Ctrl+T (keyCode=17, modifiers=4096) 12 次，但 `handleCGEvent` 中的 title editor 分支（lines 134-159）从未被执行——无任何 "Title editor Ctrl+T matched" 日志输出。

**Architecture:** CGEventTap 回调 → `handleCGEvent` (@MainActor) → title editor 检测（失败点）→ `TitleEditorService.editTitle()`。问题出在 `handleCGEvent` 的 title editor 分支从未被触发，最可能原因是 `@MainActor` + `StrictConcurrency` 导致方法执行在 title editor 检测前中断。修复方案：将 Ctrl+T 检测从 `@MainActor` 方法中提取到 nonisolated 上下文，并添加 Carbon 热键作为额外保障。

**Tech Stack:** Swift 5.9, macOS 13+, Carbon HotKey API, CGEventTap, StrictConcurrency

**Risks:**
- Task 1 修改 CGEventTap 回调可能影响 toggle 热键（Ctrl+Q） → 缓解：toggle 热键逻辑保持不变，仅提取 title editor 部分
- Task 2 Carbon 热键注册可能与其他应用冲突 → 缓解：Carbon 热键在应用级注册，不会与 iTerm2 等终端冲突

---

### Task 1: Extract Title Editor Detection from @MainActor handleCGEvent

**Depends on:** None
**Files:**
- Modify: `Sources/HotKey/HotKeyManager+EventTap.swift:26-31`（CGEventTap 回调）
- Modify: `Sources/HotKey/HotKeyManager+EventTap.swift:62-163`（handleCGEvent 方法）
- Modify: `Sources/HotKey/HotKeyManager.swift`（添加 title editor 触发方法）

- [ ] **Step 1: 修改 HotKeyManager — 添加 nonisolated title editor 触发方法**

在 `HotKeyManager.swift` 中添加一个 nonisolated 静态方法来处理 title editor 热键触发，绕过 @MainActor 限制。

文件: `Sources/HotKey/HotKeyManager.swift`（在 `private init()` 之后添加）

```swift
/// Nonisolated entry point for title editor hotkey — bypasses @MainActor
/// to avoid StrictConcurrency dispatch issues from CGEventTap C callback.
nonisolated static func triggerTitleEditor() {
    let enabled = TitleEditorPreferences.isEnabled
    let hotKeyEnabled = TitleEditorPreferences.isHotKeyEnabled
    NSLog("[HotKey] Title editor Ctrl+T matched enabled=%d hotKeyEnabled=%d", enabled, hotKeyEnabled)
    guard enabled && hotKeyEnabled else {
        NSLog("[HotKey] Title editor disabled, passing event through")
        return
    }
    NSLog("[HotKey] Title editor hotkey detected, dispatching editTitle")
    DispatchQueue.main.async {
        TitleEditorService.shared.editTitle()
    }
}
```

- [ ] **Step 2: 修改 CGEventTap 回调 — 在 C callback 中直接检测 Ctrl+T**

将 title editor 的 Ctrl+T 检测逻辑从 `handleCGEvent` 方法移到 CGEventTap C 回调中，避免 @MainActor dispatch 问题。

文件: `Sources/HotKey/HotKeyManager+EventTap.swift:26-31`

```swift
// 替换整个 callback 闭包（lines 26-31）
callback: { proxy, type, event, refcon in
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()

    // Title editor hotkey: Ctrl+T — detect BEFORE @MainActor dispatch
    if type == .keyDown {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let hasControl = flags.contains(.maskControl)
        let hasCommand = flags.contains(.maskCommand)
        let hasAlt = flags.contains(.maskAlternate)
        let hasShift = flags.contains(.maskShift)

        if keyCode == 17 && hasControl && !hasCommand && !hasAlt && !hasShift
            && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
        {
            HotKeyManager.triggerTitleEditor()
            return nil
        }
    }

    return manager.handleCGEvent(proxy: proxy, type: type, event: event)
},
```

- [ ] **Step 3: 删除 handleCGEvent 中的 title editor 代码**

从 `handleCGEvent` 方法中删除已迁移到回调中的 title editor 检测代码，避免重复处理。

文件: `Sources/HotKey/HotKeyManager+EventTap.swift:133-160`

删除以下代码块（title editor 相关的 keyCode/modifiers 检测和 editTitle 调用）:

```swift
// 删除 lines 134-159 的 title editor 代码块:
// let titleEditorKeyCode: UInt32 = 17
// let titleEditorModifiers: UInt32 = UInt32(controlKey)
// if keyCode == titleEditorKeyCode && modifiers == titleEditorModifiers { ... }
```

保留最后的 `return Unmanaged.passUnretained(event)`。

修改后的 `handleCGEvent` 方法尾部应该从 line 132 的 `return nil`（toggle hotkey）之后直接到 `return Unmanaged.passUnretained(event)`。

- [ ] **Step 4: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 5: 提交**
Run: `git add Sources/HotKey/HotKeyManager+EventTap.swift Sources/HotKey/HotKeyManager.swift && git commit -m "fix(hotkey): extract Ctrl+T title editor detection from @MainActor to fix silent failure"`

---

### Task 2: Register Ctrl+T as Carbon HotKey for Fallback Reliability

**Depends on:** Task 1
**Files:**
- Modify: `Sources/HotKey/HotKeyManager.swift:21-24`（添加 Carbon 热键变量）
- Modify: `Sources/HotKey/HotKeyManager+CarbonHotKey.swift:47-69`（添加注册逻辑）
- Modify: `Sources/HotKey/HotKeyManager+CarbonHotKey.swift:72-117`（添加处理逻辑）

- [ ] **Step 1: 添加 Carbon 热键变量到 HotKeyManager**

在 `HotKeyManager.swift` 中添加 Ctrl+T Carbon 热键的引用变量。

文件: `Sources/HotKey/HotKeyManager.swift:23`（在 `var hotKeyRef: EventHotKeyRef?` 之后添加）

```swift
var titleEditorHotKeyRef: EventHotKeyRef?
```

- [ ] **Step 2: 修改 Carbon 热键注册 — 注册第二个 Carbon 热键用于 Ctrl+T**

在 `registerHotKey()` 方法中，在注册 toggle 热键之后，注册 Ctrl+T 作为第二个 Carbon 热键。

文件: `Sources/HotKey/HotKeyManager+CarbonHotKey.swift:47-69`（在现有 `registerHotKey` 方法末尾，`log` 之后添加）

在 `CrashContextRecorder.shared.record(...)` 行之后添加:

```swift
// Register title editor hotkey: Ctrl+T (keyCode 17)
if let titleEditorHotKeyRef {
    UnregisterEventHotKey(titleEditorHotKeyRef)
    self.titleEditorHotKeyRef = nil
}

let titleEditorHotKeyID = EventHotKeyID(signature: hotkeySignature, id: 2)
let titleEditorStatus = RegisterEventHotKey(
    17,  // kVK_ANSI_T
    UInt32(controlKey),
    titleEditorHotKeyID,
    GetApplicationEventTarget(),
    0,
    &titleEditorHotKeyRef
)

if titleEditorStatus == noErr {
    log("[HotKey] Registered title editor Carbon hotkey Ctrl+T")
} else {
    log("[HotKey] Failed to register title editor Carbon hotkey: \(titleEditorStatus)", level: .warn)
}
```

- [ ] **Step 3: 修改 Carbon 热键处理 — 识别 title editor 热键 ID**

在 `handleHotKeyEvent` 中添加对 title editor 热键 ID (id=2) 的处理。

文件: `Sources/HotKey/HotKeyManager+CarbonHotKey.swift:96-116`（替换 hotKeyID 检查后的处理逻辑）

将现有的 `guard hotKeyID.signature == hotkeySignature, hotKeyID.id == hotkeyIdentifier` 块替换为:

```swift
guard hotKeyID.signature == hotkeySignature else {
    log("[HotKey] ID mismatch, ignoring")
    return noErr
}

if hotKeyID.id == hotkeyIdentifier {
    log("[HotKey] Hotkey \(currentHotKey.displayString) triggered")
    triggerToggleIfNeeded(source: "carbon_hotkey")
    log("[HotKey] handleHotKeyEvent finished")
    return noErr
}

if hotKeyID.id == 2 {
    log("[HotKey] Title editor Carbon hotkey triggered")
    HotKeyManager.triggerTitleEditor()
    return noErr
}

log("[HotKey] Unknown hotkey id=\(hotKeyID.id), ignoring")
return noErr
```

- [ ] **Step 4: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 5: 部署并验证**
Run: `bash scripts/deploy.sh && open /Applications/VibeFocus.app`
Expected:
  - Exit code: 0
  - App launches successfully

在 iTerm2 窗口上按 Ctrl+T，然后检查日志:
Run: `sleep 3 && grep "Title editor" ~/Library/Logs/VibeFocus/vibefocus.log | tail -5`
Expected:
  - Output contains: "Title editor Ctrl+T matched"
  - Output contains: "Title editor hotkey detected"

- [ ] **Step 6: 提交**
Run: `git add Sources/HotKey/HotKeyManager.swift Sources/HotKey/HotKeyManager+CarbonHotKey.swift && git commit -m "fix(hotkey): register Ctrl+T as Carbon hotkey for title editor fallback reliability"`
