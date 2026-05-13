# Window Module Bug Review & Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 Window 模块中 7 个已确认的逻辑 bug，涵盖坐标转换错误、无效 ToggleRecord 写入、AppleScript 注入漏洞、以及主屏判断不一致。

**Architecture:** 修复从底层到上层：坐标转换基础函数 → frame 读取逻辑 → toggle/restore 决策路径 → SystemEvents fallback → 安全漏洞。每个 Task 修复一类根因，上层 Task 依赖底层修复。

**Tech Stack:** Swift 5.9, macOS 14+, AX API, CGWindowList API, yabai, SQLite3

**Risks:**
- Task 1 修改 isWindowOnMainScreen 坐标转换，所有依赖此函数的逻辑都会受影响 → 缓解：此 bug 是坐标 Y 轴转换错误，修复后所有调用方都更正确
- Task 2 修改 readAccurateFrame，影响 toggle/restore 的 frame 读取 → 缓解：只修复主屏窗口的误覆盖问题，副屏窗口行为不变
- Task 4 修改 SystemEvents fallback 路径，该路径较少触发 → 缓解：修复后 AX 可用时不会走此路径，影响范围有限

---

### Task 1: 修复 isWindowOnMainScreen Quartz→AppKit 坐标转换错误

**Root Cause:** `isWindowOnMainScreen` 从 CGWindowList 获取的坐标是 Quartz 坐标系（原点在左上角），但 `mainScreenFrame` 是 AppKit 坐标系（原点在左下角）。当前代码的 Y 轴转换公式 `appKitY = mainScreenHeight - quartzY` 缺少减去窗口高度的步骤，导致靠近屏幕底部的窗口被误判为不在主屏。

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+ScreenPosition.swift:46-58`（替换 isWindowOnMainScreen 中的坐标转换逻辑）

- [ ] **Step 1: 修复 isWindowOnMainScreen 坐标转换 — Quartz Y 转 AppKit Y 需要减去窗口高度**

文件: `Sources/Window/WindowManager+ScreenPosition.swift:46-58`（替换 `let windowFrame = CGRect(...)` 到 `let onMainScreen = ...` 区块）

```swift
            let windowFrame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )
            // CGWindowList 返回 Quartz 坐标（原点左上角），NSScreen 使用 AppKit 坐标（原点左下角）
            // 转换公式: appKitY = mainScreenHeight - quartzY - windowHeight
            let mainScreenHeight = NSScreen.screens[0].frame.height
            let appKitOrigin = CGPoint(
                x: windowFrame.origin.x,
                y: mainScreenHeight - windowFrame.origin.y - windowFrame.height
            )
            let appKitCenter = CGPoint(
                x: windowFrame.midX,
                y: appKitOrigin.y + windowFrame.height / 2
            )
            let onMainScreen = mainScreenFrame.contains(appKitCenter)
```

- [ ] **Step 2: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `git add Sources/Window/WindowManager+ScreenPosition.swift && git commit -m "fix(window): correct Quartz→AppKit Y-axis conversion in isWindowOnMainScreen"`

---

### Task 2: 修复 readAccurateFrame 对主屏窗口的 yabai 误覆盖

**Root Cause:** `readAccurateFrame` 在 yabai 报告的 frame 与 AX frame 偏差 > 3×tolerance 时无条件使用 yabai frame。但窗口在主屏时，AX frame 是准确的（可见窗口），yabai 坐标是 display-relative 而非 global，两者坐标系不同导致 yabai 的 "偏差" 是正常现象。结果：主屏窗口的 frame 被错误替换为 yabai 的 display-relative 坐标。

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Window/WindowManager+AXHelpers.swift:99-123`（替换 readAccurateFrame 函数体）

- [ ] **Step 1: 修复 readAccurateFrame — 主屏窗口信任 AX frame，仅副屏窗口使用 yabai 覆盖**

文件: `Sources/Window/WindowManager+AXHelpers.swift:99-123`（替换整个 readAccurateFrame 函数）

```swift
    func readAccurateFrame(windowID: UInt32, axElement: AXUIElement) -> CGRect? {
        guard let axFrame = frame(of: axElement) else {
            return nil
        }
        // 主屏上的窗口 AX frame 是准确的（可见窗口），不需要 yabai 交叉校验
        // yabai frame 是 display-relative 坐标，与 AX 的 global 坐标不同
        // 对主屏窗口做 yabai override 会把正确的 global 坐标替换成错误的 display-relative 坐标
        if isWindowOnMainScreen(windowID: windowID) {
            return axFrame
        }
        guard let yabaiInfo = spaceController.queryWindow(windowID: windowID),
              let yabaiFrame = yabaiInfo.frame else {
            return axFrame
        }
        let yabaiRect = yabaiFrame.cgRect
        let positionDiff = hypot(yabaiRect.midX - axFrame.midX, yabaiRect.midY - axFrame.midY)
        if positionDiff > frameTolerance * 3 {
            log(
                "[WindowManager] readAccurateFrame: yabai override",
                level: .info,
                fields: [
                    "windowID": String(windowID),
                    "axFrame": "\(axFrame)",
                    "yabaiFrame": "\(yabaiRect)",
                    "positionDiff": String(format: "%.0f", positionDiff)
                ]
            )
            return yabaiRect
        }
        return axFrame
    }
```

- [ ] **Step 2: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `git add Sources/Window/WindowManager+AXHelpers.swift && git commit -m "fix(window): skip yabai override for main-screen windows in readAccurateFrame"`

---

### Task 3: 修复 findClaudeCodeWindow 中用 Quartz 坐标判断主屏 + isWindowOnMainScreen 未复用

**Root Cause:** `findClaudeCodeWindow` 内部自己用 `mainScreenFrame.contains(center)` 判断窗口是否在主屏，但 `center` 来自 CGWindowList 的 Quartz 坐标，而 `mainScreenFrame` 是 AppKit 坐标。坐标系不匹配导致判断错误。同时该函数应该复用已有的 `isWindowOnMainScreen` 而不是重复实现。

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Window/WindowManager+Finding.swift:143-186`（替换 WindowCandidate 构建和 isOnMainScreen 赋值逻辑）

- [ ] **Step 1: 修复 findClaudeCodeWindow — 用 isWindowOnMainScreen 替代手动坐标判断**

文件: `Sources/Window/WindowManager+Finding.swift:156-168`（替换 `let isOnMainScreen: Bool` 区块）

```swift
            let isOnMainScreen: Bool = isWindowOnMainScreen(windowID: windowID)
```

同时移除 `let mainScreen = getMainScreen()` 和 `let mainScreenFrame = mainScreen?.frame`（第 122-123 行），以及 `WindowCandidate` struct 中的 `isOnMainScreen` 字段（第 19 行），改为在策略匹配时直接调用 `isWindowOnMainScreen`。

由于 `WindowCandidate` 中 `isOnMainScreen` 字段在策略匹配中实际未使用（策略只匹配 app name + title），最小改动方案是：只修复 `isOnMainScreen` 的赋值，保留字段但使用正确函数。

文件: `Sources/Window/WindowManager+Finding.swift:156-168`（替换整个 isOnMainScreen 计算区块）

```swift
            let isOnMainScreen = isWindowOnMainScreen(windowID: windowID)
```

- [ ] **Step 2: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `git add Sources/Window/WindowManager+Finding.swift && git commit -m "fix(window): use isWindowOnMainScreen instead of broken manual Quartz coordinate check"`

---

### Task 4: 修复 SystemEvents fallback 写入无效 ToggleRecord (sourceSpace=0)

**Root Cause:** `moveToMainScreenViaSystemEvents` 在 AX 不可用时作为 fallback 路径调用 `ToggleEngine.shared.save(sourceSpace: 0, sourceDisplay: 0, ...)`。但 ToggleEngine.save 的验证逻辑会拒绝 origFrame 在主屏上的记录，而 SystemEvents fallback 保存的记录 sourceSpace=0 是无效的 yabai index。后续 restore 时 `switchDisplayToSpace(targetSpace: 0)` 会失败或切换到错误的 Space。

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Window/WindowManager+SystemEvents.swift:39-54`（替换 ToggleEngine.save 调用）
- Modify: `Sources/Window/WindowManager+SystemEvents.swift:91-115`（修复 shouldRestoreCurrentWindowViaSystemEvents 的有效性判断）

- [ ] **Step 1: 修复 moveToMainScreenViaSystemEvents — 不保存无效 sourceSpace=0 的 ToggleRecord**

文件: `Sources/Window/WindowManager+SystemEvents.swift:39-54`（替换 `if let windowID = snapshot.windowID { ... }` 区块）

```swift
        // 不保存 sourceSpace=0 的 ToggleRecord — 0 是无效 yabai index，restore 时会切换到错误 Space
        // SystemEvents fallback 无法获取 yabai space 信息，无法安全地支持 toggle-restore
        if let windowID = snapshot.windowID {
            log(
                "[WindowManager] SystemEvents fallback moved window but skipping ToggleEngine.save (no yabai space info)",
                level: .warn,
                fields: ["windowID": String(windowID)]
            )
        }
```

- [ ] **Step 2: 修复 shouldRestoreCurrentWindowViaSystemEvents — 增加 sourceSpace 有效性检查**

文件: `Sources/Window/WindowManager+SystemEvents.swift:91-115`（替换整个 shouldRestoreCurrentWindowViaSystemEvents 函数）

```swift
    func shouldRestoreCurrentWindowViaSystemEvents() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let snapshot = systemEventsSnapshot(forPID: frontApp.processIdentifier) else {
            return false
        }

        if let currentWindowID = snapshot.windowID,
           let record = ToggleEngine.shared.load(windowID: currentWindowID) {
            guard let mainScreen = getMainScreen() else { return false }
            if !record.isValid(mainScreenFrame: mainScreen.frame) {
                log(
                    "System Events match found but toggle record corrupted, clearing",
                    level: .warn,
                    fields: ["windowID": String(describing: currentWindowID)]
                )
                ToggleEngine.shared.clear(windowID: currentWindowID)
            } else if record.sourceSpace > 0 {
                // sourceSpace=0 是无效 yabai index（SystemEvents fallback 写入的），不支持 restore
                log("Detected valid toggle record via System Events, windowID=\(currentWindowID)")
                return true
            } else {
                log(
                    "System Events found toggle record with sourceSpace=0, clearing (invalid yabai index)",
                    level: .warn,
                    fields: ["windowID": String(currentWindowID)]
                )
                ToggleEngine.shared.clear(windowID: currentWindowID)
            }
        }

        return false
    }
```

- [ ] **Step 3: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 4: 提交**
Run: `git add Sources/Window/WindowManager+SystemEvents.swift && git commit -m "fix(window): skip invalid ToggleRecord save in SystemEvents fallback, reject sourceSpace=0 in restore"`

---

### Task 5: 修复 matchTerminalWindowByAppleScript 中的 AppleScript 注入漏洞

**Root Cause:** `matchTerminalWindowByAppleScript` 将用户控制的 TTY 路径直接拼接到 osascript 字符串中（`if tty of tb is "\(fullTTY)"`）。恶意构造的 TTY 路径可以注入 AppleScript 代码。例如 TTY 为 `ttys001" then tell application "Finder" to delete ...` 可执行任意 AppleScript。

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+TerminalContext.swift:172-186`（替换 AppleScript 生成逻辑）

- [ ] **Step 1: 修复 matchTerminalWindowByAppleScript — 对 TTY 路径做转义防止 AppleScript 注入**

文件: `Sources/Window/WindowManager+TerminalContext.swift:172-186`（替换 `let script = """` 区块中的 TTY 插值）

```swift
        // 对 TTY 路径做 AppleScript 转义：替换双引号和反斜杠，防止注入
        let escapedTTY = fullTTY
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        osascript -e 'tell application "Terminal"
            set winCount to count of windows
            repeat with i from 1 to winCount
                try
                    repeat with tb in tabs of window i
                        if tty of tb is "\(escapedTTY)" then
                            return (id of window i) as text
                        end if
                    end repeat
                end try
            end repeat
            return ""
        end tell'
        """
```

- [ ] **Step 2: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `git add Sources/Window/WindowManager+TerminalContext.swift && git commit -m "fix(security): escape TTY path in AppleScript to prevent injection in matchTerminalWindowByAppleScript"`