# Refactor: Overlay 日志精简 + WindowIdentity Factory Method

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 精简 Overlay/ 目录 4 个文件的高密度 debug log（总计 102 个 log 调用）；提取 WindowIdentity 便利构造器消除 5 处重复的字段赋值。

**Architecture:** 纯提取和删除 — 删除 entry/exit debug log；给 WindowIdentity 添加从窗口属性直接构造的便利 init。数据流不变。

**Safety Net:** `swift build` 编译验证
**Scope:** Small
**Risk:** Low

**Before/After:**
- Before: Overlay/ 4 个文件共 102 个 log 调用，log 密度 11-13/100 lines；WindowIdentity 构造在 5 处重复 7 个字段赋值
- After: Overlay/ 保留决策点日志，移除 routine refresh 日志；WindowIdentity 有便利构造器

**Risks:**
- Overlay 日志精简可能移除有用的调试信息 → 缓解：保留空间变更检测日志和 warn/error 日志
- WindowIdentity 便利构造器可能遗漏某些调用点的特殊字段 → 缓解：逐一检查每个调用点

**Autonomy Level:** Full

---

### Task 1: 精简 ScreenOverlayManager+SpaceIndex 日志

**Depends on:** None
**Files:**
- Modify: `Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift`

**问题分析：** 269 行有 36 个 log 调用（13.4/100 lines）。`refreshSpaceIndices()` 每次刷新记录每个屏幕的详细空间信息，`getPerScreenSpaceIndex()` 和 `getYabaiSpaceIndex()` 有大量 entry/exit debug log。这些日志在正常刷新循环中产生海量噪音。应保留空间变更检测日志和 warn/error 日志。

- [ ] **Step 1: 读取文件并精简 refreshSpaceIndices 中的 routine 日志**

文件: `Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift`

移除以下类型的 debug log：
- 方法 entry/exit 日志（"refreshSpaceIndices called"、"refreshSpaceIndices completed"）
- 每个屏幕的 routine 状态日志（无变化时的日志）
- 中间步骤的 debug 日志（"found displayIndex"、"checking display"）

保留：
- 空间变更检测日志（"space index changed"）
- warn/error 日志（"query failed"、"no visible space"）

- [ ] **Step 2: 精简 getPerScreenSpaceIndex 和 getYabaiSpaceIndex 中的 entry/exit 日志**

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift && git commit -m "refactor(overlay): thin verbose debug logging in ScreenOverlayManager+SpaceIndex"`

---

### Task 2: 精简 ScreenOverlayManager+Signal 和 ScreenOverlayManager 日志

**Depends on:** None
**Files:**
- Modify: `Sources/Overlay/ScreenOverlayManager+Signal.swift`（15 logs / 114 lines = 13.2/100）
- Modify: `Sources/Overlay/ScreenOverlayManager.swift`（26 logs / 210 lines = 12.4/100）

- [ ] **Step 1: 读取并精简 ScreenOverlayManager+Signal.swift**

移除信号处理的 entry/exit debug log，保留实际的信号触发和错误日志。

- [ ] **Step 2: 读取并精简 ScreenOverlayManager.swift**

移除 overlay 刷新的 routine debug log，保留实际的 overlay 创建/销毁日志和错误日志。

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/Overlay/ScreenOverlayManager+Signal.swift Sources/Overlay/ScreenOverlayManager.swift && git commit -m "refactor(overlay): thin verbose debug logging in ScreenOverlayManager+Signal and ScreenOverlayManager"`

---

### Task 3: 精简 ScreenIndexPreferences load() 日志

**Depends on:** None
**Files:**
- Modify: `Sources/Overlay/ScreenIndexPreferences.swift`（25 logs / 227 lines = 11.0/100）

- [ ] **Step 1: 读取并精简 ScreenIndexPreferences.swift**

`load()` 方法有 15 个 debug log，每个步骤都有 entry/exit。精简为：方法入口一个 debug log + 最终结果一个 info log + 错误日志。删除所有中间步骤的 debug log。

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Overlay/ScreenIndexPreferences.swift && git commit -m "refactor(overlay): thin verbose debug logging in ScreenIndexPreferences.load()"`

---

### Task 4: 添加 WindowIdentity 便利构造器

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/ClaudeHookModels.swift`（添加便利 init）
- Modify: `Sources/Window/WindowManager+Finding.swift`（替换 2 处构造）
- Modify: `Sources/Window/WindowManager+TerminalContext.swift`（替换 2 处构造）
- Modify: `Sources/Hook/HookEventHandler+WindowMove.swift`（替换 1 处构造）

**问题分析：** 5 处代码用相同的字段赋值模式构造 WindowIdentity：
```swift
WindowIdentity(
    windowID: windowID,
    pid: pid,
    bundleIdentifier: bundleID,
    appName: appName,
    windowNumber: axWindowNumber, // 或 nil
    title: title,
    capturedAt: Date()
)
```

还有从 WindowState 构造的模式（HookEventHandler+WindowMove.swift:169）：
```swift
WindowIdentity(
    windowID: windowID,
    pid: binding.pid,
    bundleIdentifier: binding.bundleIdentifier,
    appName: binding.appName,
    windowNumber: binding.axWindowNumber,
    title: binding.title,
    capturedAt: binding.createdAt
)
```

- [ ] **Step 1: 在 ClaudeHookModels.swift 添加便利构造器**

文件: `Sources/Hook/ClaudeHookModels.swift`（在 WindowIdentity struct 内添加）

```swift
/// 从窗口属性直接构造
init(windowID: UInt32, pid: Int32, bundleIdentifier: String?, appName: String?, windowNumber: Int? = nil, title: String?) {
    self.windowID = windowID
    self.pid = pid
    self.bundleIdentifier = bundleIdentifier
    self.appName = appName
    self.windowNumber = windowNumber
    self.title = title
    self.capturedAt = Date()
}

/// 从 WindowState 构造（保留原始 capturedAt）
init(from state: WindowState) {
    self.windowID = state.windowID
    self.pid = state.pid
    self.bundleIdentifier = state.bundleIdentifier
    self.appName = state.appName
    self.windowNumber = state.axWindowNumber
    self.title = state.title
    self.capturedAt = state.createdAt
}
```

- [ ] **Step 2: 替换 WindowManager+Finding.swift 中的构造**
- [ ] **Step 3: 替换 WindowManager+TerminalContext.swift 中的构造**
- [ ] **Step 4: 替换 HookEventHandler+WindowMove.swift 中的构造**
- [ ] **Step 5: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 6: 提交**
Run: `git add Sources/Hook/ClaudeHookModels.swift Sources/Window/WindowManager+Finding.swift Sources/Window/WindowManager+TerminalContext.swift Sources/Hook/HookEventHandler+WindowMove.swift && git commit -m "refactor: add WindowIdentity convenience initializers to eliminate repeated construction"`
