# Dead Code and Redundancy Cleanup

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 清理被 ToggleEngine 重写后遗留的死代码，移除 455 行完全废弃的 SpaceStrategy 文件、6 个从未被调用的 State 管理函数、以及一直为空的 crash context 字段。

**Architecture:** ToggleEngine 重写后，restore 流程直接从 SQLite 读 ToggleRecord → 空间预切换 → AX frame 应用。旧的 `applySpaceStrategyForRestore()` 和 `savedWindowStates` 内存缓存已无调用方。清理顺序：删除最大死文件 → 移除 State 层死函数 → 简化 WindowQuery 中的 stale cache 检查 → 构建验证。

**Tech Stack:** Swift 5.9, macOS 13+

**Risks:**
- Task 2 删除 `savedWindowStates` 相关代码会影响 crash context 日志中的 `savedStates` 字段 → 但该字段一直为 0（ToggleEngine 不写 savedWindowStates），影响极小
- Task 3 简化 WindowQuery 会移除 `lastWindowElement` 缓存路径 → 该路径一直为 nil（只有死函数写入），移除后不影响实际行为

---

### Task 1: 删除 WindowManager+SpaceStrategy.swift — 455 行完全废弃的 Space 策略代码

**Depends on:** None
**Files:**
- Delete: `Sources/Window/WindowManager+SpaceStrategy.swift`

- [ ] **Step 1: 确认文件无外部调用方**

Run: `grep -rn "applySpaceStrategyForRestore\|resolveSourceSpaceIndexForRestore" Sources/ --include="*.swift" | grep -v "WindowManager+SpaceStrategy.swift" | grep -v "func "`
Expected:
  - Output is empty (无外部调用方)

- [ ] **Step 2: 删除文件**

Run: `rm Sources/Window/WindowManager+SpaceStrategy.swift`

- [ ] **Step 3: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Output contains: "Build complete!"

---

### Task 2: 移除 State 层死函数和 savedWindowStates 冗余逻辑

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Window/WindowManager.swift` — 移除 `savedWindowStates` 数组、`savedStatesKey`、初始化中的加载逻辑
- Modify: `Sources/Window/WindowManager+State.swift` — 移除 6 个死函数，保留 `loadSavedWindowStates` 的 SQLite 调用方兼容
- Modify: `Sources/Window/WindowManager+Toggle.swift:406-436` — 移除 `isSavedStateCorrupted()` 死函数
- Modify: `Sources/Support/CrashContext.swift` — 移除 `lastWindow*` 冗余字段（一直为 nil）

- [ ] **Step 1: 移除 isSavedStateCorrupted() 死函数**
文件: `Sources/Window/WindowManager+Toggle.swift:406-436`（删除整个 `isSavedStateCorrupted` 方法）

```swift
// 删除 Sources/Window/WindowManager+Toggle.swift:406-436 的 isSavedStateCorrupted 方法
// 该方法从未被外部调用
```

- [ ] **Step 2: 简化 WindowManager+State.swift — 移除死函数**
文件: `Sources/Window/WindowManager+State.swift`（替换整个文件内容）

```swift
import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - Window State Management
@MainActor
extension WindowManager {

    func loadSavedWindowStates() -> [SavedWindowState] {
        let states = WindowStateStore.shared.loadStates()
        log("Loaded \(states.count) window state(s) from SQLite")
        return states
    }
}
```

- [ ] **Step 3: 移除 WindowManager.swift 中的 savedWindowStates 属性和初始化逻辑**
文件: `Sources/Window/WindowManager.swift`

删除以下内容:
- `let savedStatesKey = "savedWindowStates"` (约 line 13)
- `var savedWindowStates: [SavedWindowState] = []` (约 line 24)
- init() 中的 `savedWindowStates = loadSavedWindowStates()` 和相关的 `if !savedWindowStates.isEmpty` 日志 (约 lines 96-99)
- `cleanupStaleStatesWithGracePeriod()` 中对 `savedWindowStates.removeAll` 的引用 (约 lines 114-117)

修改后 `cleanupStaleStatesWithGracePeriod()`:

```swift
    private func cleanupStaleStatesWithGracePeriod() {
        let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let existingWindowIDs = Set(windowList.compactMap { $0["kCGWindowNumber"] as? UInt32 })

        let gracePeriod: TimeInterval = 5 * 60
        let removed = WindowStateStore.shared.cleanupStaleStates(
            existingWindowIDs: existingWindowIDs,
            gracePeriod: gracePeriod
        )

        if removed > 0 {
            log("[WindowManager] cleanup with grace period: removed \(removed) stale state(s)")
        }
    }
```

- [ ] **Step 4: 移除 CrashContext 中的 lastWindow* 冗余字段**
文件: `Sources/Support/CrashContext.swift`

移除对以下 WindowManager 属性的引用:
- `lastWindowToken` — 只有死函数写入
- `lastWindowFrame` — 只有死函数写入
- `lastTargetFrame` — 只有死函数写入
- `lastWindowElement` — 只有死函数写入
- `lastSourceSpaceIndex` — 只有死函数写入
- `lastSourceYabaiDisplayIndex` — 只有死函数写入
- `lastSourceDisplaySpaceIndex` — 只有死函数写入
- `windowElementsByStateID` — 只有死函数写入
- `savedWindowStates` — 已删除

只保留 `CrashContext` 中对其他有效属性的引用（如 `ToggleEngine`、`SpaceController` 状态等）。

- [ ] **Step 5: 移除 WindowManager.swift 中的 lastWindow* 属性声明**
文件: `Sources/Window/WindowManager.swift`

删除以下属性声明:
- `var lastWindowElement: AXUIElement?`
- `var lastWindowToken: WindowToken?`
- `var lastWindowFrame: CGRect?`
- `var lastTargetFrame: CGRect?`
- `var lastSourceSpaceIndex: Int?`
- `var lastTargetSpaceIndex: Int?`
- `var lastSourceYabaiDisplayIndex: Int?`
- `var lastSourceDisplaySpaceIndex: Int?`
- `var windowElementsByStateID: [String: AXUIElement]`

- [ ] **Step 6: 验证编译**
Run: `swift build -c release 2>&1 | tail -10`
Expected:
  - Output contains: "Build complete!"
  - Output does NOT contain: "error:"

---

### Task 3: 简化 WindowQuery 中的 stale cache 检查

**Depends on:** Task 2
**Files:**
- Modify: `Sources/Window/WindowManager+WindowQuery.swift` — 移除 `lastWindowElement`/`lastWindowToken`/`lastTargetFrame` 引用

- [ ] **Step 1: 移除 WindowQuery 中对已删除属性的引用**
文件: `Sources/Window/WindowManager+WindowQuery.swift`（约 lines 70-103）

将使用 `lastWindowElement`/`lastWindowToken`/`lastTargetFrame` 的三级匹配逻辑简化为两级: PID 遍历 + 备用匹配（PID + 标题 + 位置）。

```swift
        // 第一级: 按 PID 遍历所有窗口查找匹配 windowID
        if let resolvedByPID = findWindowByPID(token.pid, windowID: token.windowID) {
            log("Restoring using PID-based window enumeration")
            return resolvedByPID
        }

        // 第二级匹配：备用匹配（PID + 标题 + 大致位置）
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let focused = focusedWindow(for: frontApp.processIdentifier),
           let currentTitle = title(of: focused),
           let currentFrame = frame(of: focused) {
```

注意：移除 `lastTargetFrame` 引用后，备用匹配中的 `lastTarget` 比较也需要移除。改为只比较 PID + 标题。

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Output contains: "Build complete!"

---

### Task 4: 构建部署 + 提交

**Depends on:** Task 1, Task 2, Task 3
**Files:**
- 无代码修改

- [ ] **Step 1: 部署**
Run: `bash scripts/dev-build.sh 2>&1 | tail -10`
Expected:
  - Output contains: "构建成功！"

- [ ] **Step 2: 启动应用**
Run: `open /Applications/VibeFocus.app`

- [ ] **Step 3: 提交**
Run: `git add -A && git commit -m "refactor: remove 455-line dead SpaceStrategy file and unused State layer functions"`
