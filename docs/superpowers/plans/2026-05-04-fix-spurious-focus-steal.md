# Fix: Spurious Focus Steal — 窗口操作后焦点被抢走

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复用户在主屏 Terminal 打字时，焦点突然被抢到 Chrome 的问题。根因是 hook 事件触发窗口移动/恢复操作时，`focusSpace()` 和 `focusWindow()` 修改了系统焦点状态且未恢复。

**Architecture:** Hook 事件 → 窗口移动/恢复 → SpaceController.focusSpace() 用 CGEvent 移动鼠标到副屏 → macOS 激活副屏上 Chrome → 鼠标移回但焦点未恢复。修复策略：在所有可能改变焦点的操作前后，保存并恢复 `NSWorkspace.shared.frontmostApplication`，确保用户当前活跃应用不被抢走。

**Tech Stack:** Swift 5.9, macOS SkyLight API, CGEvent, yabai 6.x

**Risks:**
- Task 1 修改 SpaceController.focusSpace() 的 CGEvent 路径 — 这是核心空间切换逻辑，需确保焦点恢复不会干扰 Space 切换本身
- Task 2 修改 focusWindow() 的调用点 — 需区分"用户主动触发的 focus"（热键）和"系统自动触发的 focus"（hook restore），前者应保留焦点切换，后者不应

---

## Pre-Planning Analysis

**Feature:** fix-spurious-focus-steal
**Scope:** multiple subsystems (SpaceController, WindowManager, HookEventHandler)
**Files Create:** none
**Files Modify:**
- `Sources/SpaceController.swift:784-849` (focusSpace CGEvent fallback — 保存/恢复焦点)
- `Sources/WindowManager.swift:327-329` (moveToMain 后 focusWindow — 仅热键路径保留)
- `Sources/WindowManager.swift:662-722` (restore — hook-restore 路径去掉 focusWindow)
- `Sources/WindowManager.swift:1395-1423` (switchToOriginal — focusWindow 条件化)
- `Sources/WindowManager.swift:1483-1507` (pullToCurrent — focusWindow 条件化)
- `Sources/SpaceController.swift:876-906` (focusWindow — 添加调用者标识)
**Tasks:** 4 tasks
**Order:** Task 1 (SpaceController 焦点保护) → Task 2 (WindowManager 条件化 focusWindow) → Task 3 (日志增强) → Task 4 (验证+提交)
**Risks:**
- Task 1: focusSpace 中恢复焦点可能导致 Space 切换失败 → 缓解：只在 CGEvent 鼠标移动路径恢复焦点，Ctrl+Arrow 之后再恢复
- Task 2: 移除 hook-restore 路径的 focusWindow 可能导致恢复的窗口不可见 → 缓解：hook-restore 本来就不应抢焦点，窗口移动到正确 Space 后用户自然看到

→ Proceeding to Phase 2...

---

### Task 1: SpaceController.focusSpace() 添加焦点保存/恢复

**Depends on:** None
**Files:**
- Modify: `Sources/SpaceController.swift:784-849`

当 `focusSpace()` 使用 CGEvent 鼠标移动到副屏时，macOS 会自动激活副屏上鼠标位置处的应用（通常是 Chrome）。移动鼠标回去后，焦点并未恢复到原来的应用。修复方法：在 CGEvent 鼠标移动前保存 `frontmostApplication`，操作完成后恢复。

- [ ] **Step 1: 修改 focusSpace() 的 CGEvent 鼠标移动路径 — 保存并恢复前台应用焦点**

文件: `Sources/SpaceController.swift:784-849`

替换 `focusSpace()` 方法中两个 CGEvent 鼠标移动代码块（steps == 0 路径和 steps != 0 路径），在鼠标移动前保存前台应用，操作完成后恢复。

```swift
// === steps == 0 路径 (line 784-816) ===
// 在 let savedCursor = NSEvent.mouseLocation 之前，添加焦点保存：
let savedFrontApp = NSWorkspace.shared.frontmostApplication

// 原有 CGEvent 鼠标移动代码不变 (line 788-800)
// ...

// 在 restoreEvent.post 之后 (line 800 后)，添加焦点恢复：
usleep(50_000)
savedFrontApp?.activate(options: .activateIgnoringOtherApps)

// === steps != 0 路径 (line 818-868) ===
// 在 let savedCursor = NSEvent.mouseLocation 之前，添加焦点保存：
// （如果 steps==0 路径已保存则复用，否则重新保存）
let savedFrontAppSteps = NSWorkspace.shared.frontmostApplication

// 原有 CGEvent 鼠标移动 + Ctrl+Arrow 代码不变 (line 825-844)
// ...

// 在鼠标位置恢复之后 (line 849 后)，添加焦点恢复：
usleep(50_000)
savedFrontAppSteps?.activate(options: .activateIgnoringOtherApps)
```

- [ ] **Step 2: 验证 SpaceController 编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

---

### Task 2: WindowManager 条件化 focusWindow 调用 — hook-restore 不抢焦点

**Depends on:** Task 1
**Files:**
- Modify: `Sources/WindowManager.swift:327-329` (moveToMain — 仅 carbon_hotkey 保留 focusWindow)
- Modify: `Sources/WindowManager.swift:662-722` (restore — hook-restore 路径已正确，验证无遗漏 focusWindow)
- Modify: `Sources/WindowManager.swift:1395-1423` (switchToOriginal — 仅 carbon_hotkey 保留 focusWindow)
- Modify: `Sources/WindowManager.swift:1483-1507` (pullToCurrent — 仅 carbon_hotkey 保留 focusWindow)

核心原则：**用户主动按热键**（carbon_hotkey）时，focusWindow 是合理的（用户明确想切换到那个窗口）；**hook 自动触发**（user_prompt_submit / stop / session_end）时，绝对不能调用 focusWindow，否则会抢走用户正在使用的应用焦点。

- [ ] **Step 1: 修改 moveToMain 后的 focusWindow — 仅热键触发时调用**

文件: `Sources/WindowManager.swift:327-329`

当前代码无条件调用 `focusWindow`：
```swift
if moved {
    _ = spaceController.focusWindow(identity.windowID, operationID: op)
}
```

但 `moveToMainScreen` 只从 `moveToMain()` 调用（热键路径），所以此处 focusWindow 可以保留。验证调用链后确认无需修改。

- [ ] **Step 2: 验证 restore 路径中 hook-restore 不调用 focusWindow**

文件: `Sources/WindowManager.swift:710-722`

当前代码已有条件判断：
```swift
if triggerSource == "carbon_hotkey" {
    // ... focusWindow ...
}
```

hook-restore 路径（user_prompt_submit）不走 focusWindow，已正确。无需修改。

- [ ] **Step 3: 修改 switchToOriginal 中的 focusWindow — 仅热键触发时调用**

文件: `Sources/WindowManager.swift:1395-1423`

当前代码在 `moveWindow` 成功后无条件调用 `focusWindow`：
```swift
if spaceController.moveWindow(windowID, toSpaceIndex: sourceSpace, focus: false, operationID: op) {
    if !spaceController.focusWindow(windowID, operationID: op) {
```

需要改为仅热键触发时调用。但 `switchToOriginal` 没有直接接收 `triggerSource` 参数。需要在调用链中传递 triggerSource。

查看 `switchToOriginal` 的调用者：

```swift
// WindowManager.swift 中 switchToOriginal 的定义和调用
```

需要给 `switchToOriginal` 方法添加 `triggerSource` 参数，在 `moveWindow` 成功后有条件地调用 `focusWindow`。

修改 `switchToOriginal` 方法签名，添加 `triggerSource: String = "unknown"` 参数，然后在 focusWindow 调用处加条件：

```swift
// 替换 line 1407
if triggerSource == "carbon_hotkey" {
    if !spaceController.focusWindow(windowID, operationID: op) {
        log(
            "[WindowManager] failed to focus restored window on source space",
            level: .warn,
            fields: [
                "op": op,
                "windowID": String(windowID),
                "space": String(sourceSpace)
            ]
        )
    }
}
```

同步修改所有 `switchToOriginal` 调用点，传递 triggerSource。

- [ ] **Step 4: 修改 pullToCurrent 中的 focusWindow — 仅热键触发时调用**

文件: `Sources/WindowManager.swift:1483-1507`

与 Step 3 同理，`pullToCurrent` 也需要 `triggerSource` 参数，条件化 focusWindow。

```swift
// 替换 line 1492
if triggerSource == "carbon_hotkey" {
    if !spaceController.focusWindow(windowID, operationID: op) {
        log(
            "[WindowManager] pullToCurrent focusWindow failed",
            level: .debug,
            fields: ["op": op, "windowID": String(windowID)]
        )
    }
}
```

同步修改所有 `pullToCurrent` 调用点，传递 triggerSource。

- [ ] **Step 5: 验证 WindowManager 编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

---

### Task 3: 增强焦点切换日志 — 记录焦点变化便于排查

**Depends on:** Task 2
**Files:**
- Modify: `Sources/SpaceController.swift:876-906` (focusWindow 添加焦点状态日志)
- Modify: `Sources/SpaceController.swift:784-849` (focusSpace CGEvent 路径添加焦点变化日志)

在所有焦点操作前后记录 `NSWorkspace.shared.frontmostApplication`，便于未来排查焦点问题。

- [ ] **Step 1: 在 focusWindow 方法中添加焦点变化日志**

文件: `Sources/SpaceController.swift:876-906`

在 `focusWindow` 方法开头和 yabai 执行后，记录前台应用变化：

```swift
func focusWindow(_ windowID: UInt32, operationID: String? = nil) -> Bool {
    let op = operationID ?? "none"
    refreshAvailabilityIfNeeded()
    guard isEnabled else {
        return false
    }

    let beforeApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"

    let windowCheck = queryWindow(windowID: windowID)
    if windowCheck == nil {
        log(
            "[SpaceController] focusWindow aborted: window does not exist",
            level: .warn,
            fields: [
                "op": op,
                "windowID": String(windowID)
            ]
        )
        return false
    }

    let variants = [
        ["-m", "window", "--focus", "\(windowID)"]
    ]
    let result = runYabaiVariants(variants: variants, operation: "focusWindow(\(windowID))", operationID: op)
    if result.success {
        let afterApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
        log(
            "[SpaceController] focusWindow completed",
            fields: [
                "op": op,
                "windowID": String(windowID),
                "beforeApp": beforeApp,
                "afterApp": afterApp,
                "focusChanged": String(beforeApp != afterApp)
            ]
        )
        return true
    }
    markOperationError(from: result.failure, fallback: "Failed to focus window \(windowID)", operationID: op)
    return false
}
```

- [ ] **Step 2: 在 focusSpace CGEvent 路径添加焦点变化日志**

文件: `Sources/SpaceController.swift` (Task 1 修改后的代码)

在保存 `savedFrontApp` 后、恢复焦点后，各记录一次日志：

```swift
// 保存焦点后
log(
    "[SpaceController] focusSpace CGEvent: saved frontmost app",
    fields: [
        "op": op,
        "savedApp": savedFrontApp?.localizedName ?? "nil",
        "targetSpace": String(spaceIndex)
    ]
)

// 恢复焦点后
let afterRestoreApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
log(
    "[SpaceController] focusSpace CGEvent: restored frontmost app",
    fields: [
        "op": op,
        "savedApp": savedFrontApp?.localizedName ?? "nil",
        "actualApp": afterRestoreApp,
        "restoreSuccess": String(savedFrontApp?.localizedName == afterRestoreApp)
    ]
)
```

- [ ] **Step 3: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

---

### Task 4: 构建验证 + 提交

**Depends on:** Task 3
**Files:**
- All modified files from Task 1-3

- [ ] **Step 1: 完整构建验证**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"
  - Output does NOT contain: "error:" or "warning:"

- [ ] **Step 2: 提交**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/SpaceController.swift Sources/WindowManager.swift && git commit -m "fix(focus): prevent spurious focus steal during hook-restore — save/restore frontmostApp in focusSpace, conditionalize focusWindow for hook vs hotkey triggers"`
