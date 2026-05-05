# Codebase Refactor: 低耦合高内聚重构

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将 VibeFocus 代码库中的大文件拆分为 300-500 行的聚焦模块，消除共享可变全局状态，降低耦合、提高内聚，从根本上减少 bug 产生。

**Architecture:** 当前架构以 Singleton 为中心，所有组件通过 `.shared` 互相访问，全局可变状态散布在 WindowManager 的实例属性中。重构后改为：每个模块只负责一个职责，模块间通过明确的接口通信，消除跨 session 状态污染。具体做法：提取类 → 迁移方法 → 更新调用方 → 删除旧代码。

**Tech Stack:** Swift 5.9+, macOS 14+, SwiftUI, AppKit, CGWindowList API

**Risks:**
- 重构过程中行为不能改变 — 每个 Task 完成后必须 `swift build` 通过
- WindowManager 的全局状态被多处引用 — 需要逐一迁移调用方
- 重构不能一次性完成 — 每个 Task 必须独立可验证

---

## 根因分析：为什么最近 bug 爆发

### Bug 清单与根因

| Bug | 表现 | 根因 | 根因类别 |
|-----|------|------|----------|
| 热键操作错误窗口 | 按 hotkey 恢复了别的窗口而非聚焦窗口 | `shouldRestoreCurrentWindow()` 优先检查全局 `lastWindowToken` 而非当前聚焦窗口 | **共享全局状态** |
| 跨 session 窗口污染 | Session A 移动窗口影响 Session B | `lastWindowToken`/`lastWindowFrame` 等 8 个全局变量在 Singleton 上共享 | **共享全局状态** |
| 虚假完成音效 | 中间 Stop 触发完成音 | `handleStop` 无法区分中间 Stop 和 session 结束 | **职责不清晰** |
| 模糊匹配错误操作 | 匹配到错误的终端窗口 | 多层 fallback 匹配策略层层降级 | **缺少清晰边界** |

### 三个结构性问题

**问题 1：文件过大，职责混乱**

| 文件 | 当前行数 | 职责数 | 目标行数 |
|------|---------|--------|---------|
| SettingsUI.swift | 2,672 | 多个设置面板 | ~400×6 |
| WindowManagerSupport.swift | 1,882 | 窗口查找 + 屏幕检测 + System Events + AX 操作 | ~350×5 |
| SpaceController.swift | 1,643 | Space 管理 + yabai 集成 | ~400×4 |
| WindowManager.swift | 1,549 | 状态管理 + 窗口移动 + 恢复 + Space 策略 | ~300×5 |
| ScreenOverlayManager.swift | 1,010 | Overlay 管理 + 屏幕索引偏好 | ~400×2 |
| ClaudeHookServer.swift | 904 | 4 种 hook 事件处理 + HTTP 服务 | ~300×3 |

**问题 2：8 个全局可变变量导致状态污染**

`WindowManager.swift:16-24` 的这些变量是所有跨 session bug 的根源：

```swift
var lastWindowElement: AXUIElement?       // 上一次操作的 AXUIElement
var lastWindowToken: WindowToken?         // 上一次操作的窗口标识
var lastWindowFrame: CGRect?              // 上一次操作的原始 frame
var lastTargetFrame: CGRect?              // 上一次操作的目标 frame
var lastSourceSpaceIndex: Int?            // 上一次操作的源 Space
var lastTargetSpaceIndex: Int?            // 上一次操作的目标 Space
var lastSourceYabaiDisplayIndex: Int?     // 上一次 yabai display
var lastSourceDisplaySpaceIndex: Int?     // 上一次 display space
var savedWindowStates: [SavedWindowState] // 所有保存的窗口状态（全局）
```

`hydrateMemory()` 方法每次 restore 前都会把这些全局变量全部覆盖写入 — 这就是污染机制。

**问题 3：函数过长，无法推理**

| 函数 | 行数 | 文件 |
|------|------|------|
| `applySpaceStrategyForRestore` | 370 行 | WindowManager.swift:1148 |
| `restore` | 322 行 | WindowManager.swift:371 |
| `toggle` | 113 行 | WindowManager.swift:163 |
| `shouldRestoreCurrentWindow` (旧版) | 175 行 | WindowManager.swift:756 |
| `findClaudeCodeWindow` | 132 行 | WindowManagerSupport.swift:105 |
| `findWindowByTerminalContext` | 100 行 | WindowManagerSupport.swift:257 |

370 行的函数 ≈ 一个完整的类。不可能在不引入 bug 的情况下修改它。

### 结论

**bug 不是因为某个逻辑写错了，而是因为代码结构让逻辑不可能写对。** 8 个全局变量、1800 行的 extension 文件、370 行的函数 — 在这种结构下，修改任何功能都有极高概率影响其他功能。

---

## 重构计划

### 优先级排序

按 bug 密度排序（最常出 bug 的文件优先重构）：

1. **WindowManager.swift** — bug 最多的文件，全局状态所在地
2. **WindowManagerSupport.swift** — 混合了 5+ 种职责的 dumping ground
3. **ClaudeHookServer.swift** — 4 种 hook 处理逻辑混在一起
4. **SpaceController.swift** — 较独立但过大
5. **SettingsUI.swift** — 最大文件但 UI 类代码膨胀可接受，优先级最低

---

### Task 1: 从 WindowManager 提取 WindowStateManager — 消除全局可变状态

**Depends on:** None
**Files:**
- Create: `Sources/WindowStateManager.swift`
- Modify: `Sources/WindowManager.swift:10-28`（全局变量声明区）
- Modify: `Sources/WindowManagerSupport.swift:1738-1857`（saveWindowState, loadSavedWindowStates, persistSavedWindowStates, clearSavedWindowState, resetActiveWindowContext, hydrateMemory）

**目标：** 将 8 个全局可变变量 + 6 个状态管理方法提取到独立的 `WindowStateManager` 类中。这是消除跨 session 状态污染的基础。

- [ ] **Step 1: 创建 WindowStateManager — 管理窗口操作上下文和持久化状态**

```swift
// Sources/WindowStateManager.swift
import Foundation
import ApplicationServices.HIServices

/// 管理窗口操作的状态上下文和持久化
/// 每个操作（move/restore）通过 OperationContext 传递状态，而非全局变量
@MainActor
final class WindowStateManager {
    static let shared = WindowStateManager()

    // MARK: - 持久化状态
    private(set) var savedWindowStates: [SavedWindowState] = []
    private let savedStatesKey = "savedWindowStates"

    // MARK: - 当前操作上下文（仅在上一次操作和下一次操作之间有效）
    private(set) var lastOperation: OperationContext?

    struct OperationContext {
        let stateID: String
        let pid: pid_t
        let bundleIdentifier: String?
        let appName: String?
        let windowID: UInt32?
        let windowNumber: Int?
        let title: String?
        let originalFrame: CGRect
        let targetFrame: CGRect
        let sourceSpaceIndex: Int?
        let targetSpaceIndex: Int?
        let sourceYabaiDisplayIndex: Int?
        let sourceDisplaySpaceIndex: Int?
    }

    private init() {
        savedWindowStates = loadSavedWindowStates()
    }

    // MARK: - 操作上下文管理

    func setOperationContext(_ context: OperationContext) {
        lastOperation = context
    }

    func clearOperationContext(removeState: Bool) {
        if removeState {
            lastOperation = nil
        }
    }

    /// 从 saved state 恢复操作上下文（替代旧的 hydrateMemory）
    func restoreContext(from state: SavedWindowState) {
        lastOperation = OperationContext(
            stateID: state.id,
            pid: state.pid,
            bundleIdentifier: state.bundleIdentifier,
            appName: state.appName,
            windowID: state.windowID,
            windowNumber: nil,
            title: state.title,
            originalFrame: state.originalFrame.cgRect,
            targetFrame: state.targetFrame.cgRect,
            sourceSpaceIndex: state.sourceSpaceIndex,
            targetSpaceIndex: state.targetSpaceIndex,
            sourceYabaiDisplayIndex: state.sourceYabaiDisplayIndex,
            sourceDisplaySpaceIndex: state.sourceDisplaySpaceIndex
        )
    }

    // MARK: - Saved State 管理

    func saveWindowState(_ state: SavedWindowState) -> SavedWindowState {
        var state = state
        if let idx = savedWindowStates.firstIndex(where: { $0.id == state.id }) {
            savedWindowStates[idx] = state
        } else {
            savedWindowStates.append(state)
        }
        persistSavedWindowStates()
        return state
    }

    func clearSavedWindowState(id: String?) {
        guard let id else { return }
        savedWindowStates.removeAll { $0.id == id }
        persistSavedWindowStates()
    }

    func findSavedState(windowID: UInt32) -> SavedWindowState? {
        savedWindowStates.reversed().first { $0.windowID == windowID }
    }

    func hasSavedState(for windowID: UInt32) -> Bool {
        savedWindowStates.contains { $0.windowID == windowID }
    }

    func shouldReplaceSavedState(new: SavedWindowState, existing: SavedWindowState) -> Bool {
        guard new.windowID == existing.windowID else { return false }
        return new.savedAt > existing.savedAt
    }

    // MARK: - Persistence

    func persistSavedWindowStates() {
        guard let data = try? JSONEncoder().encode(savedWindowStates) else { return }
        UserDefaults.standard.set(data, forKey: savedStatesKey)
    }

    private func loadSavedWindowStates() -> [SavedWindowState] {
        guard let data = UserDefaults.standard.data(forKey: savedStatesKey),
              let decoded = try? JSONDecoder().decode([SavedWindowState].self, from: data) else {
            return []
        }
        return decoded
    }
}
```

- [ ] **Step 2: 修改 WindowManager — 移除全局变量，改为引用 WindowStateManager**

文件: `Sources/WindowManager.swift:10-28`（类属性声明区，替换全局变量为 WindowStateManager 引用）

```swift
// 替换 Sources/WindowManager.swift:10-28 的类声明和属性区
@MainActor
class WindowManager {
    static let shared = WindowManager()

    let spaceController = SpaceController.shared
    let stateManager = WindowStateManager.shared
    var windowElementsByStateID: [String: AXUIElement] = [:]
    var didPromptForAccessibility = false
    let frameTolerance: CGFloat = 10
    let axWindowNumberAttribute = "AXWindowNumber"
    let axFrameAttribute = "AXFrame"
```

注意：`lastWindowElement`、`lastWindowToken`、`lastWindowFrame`、`lastTargetFrame`、`lastSourceSpaceIndex`、`lastTargetSpaceIndex`、`lastSourceYabaiDisplayIndex`、`lastSourceDisplaySpaceIndex`、`savedWindowStates` 这 9 个变量全部移除，改为通过 `stateManager.lastOperation` 和 `stateManager.savedWindowStates` 访问。

- [ ] **Step 3: 验证编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - 可能出现引用旧变量的编译错误（预期中，下一步修复）

- [ ] **Step 4: 更新所有引用旧全局变量的代码 — 批量替换**

在 WindowManager.swift 和 WindowManagerSupport.swift 中：
- `lastWindowToken` → `stateManager.lastOperation` (需逐个适配属性访问)
- `savedWindowStates` → `stateManager.savedWindowStates`
- `hydrateMemory(from:window:)` → `stateManager.restoreContext(from:)`
- `saveWindowState(_:window:)` → `stateManager.saveWindowState(_:)`
- `clearSavedWindowState(id:)` → `stateManager.clearSavedWindowState(id:)`
- `resetActiveWindowContext(removeState:)` → `stateManager.clearOperationContext(removeState:)`

由于引用点较多（约 30+ 处），逐个文件适配：
1. WindowManager.swift 中所有对旧变量的读写
2. WindowManagerSupport.swift 中所有对旧变量的读写
3. 其他文件中对 `WindowManager.shared.savedWindowStates` 的引用

- [ ] **Step 5: 验证构建通过**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 6: 部署验证**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/dev-build.sh`
Expected:
  - Output contains: "✅ 构建成功！"

- [ ] **Step 7: 提交**

Run: `git add Sources/WindowStateManager.swift Sources/WindowManager.swift Sources/WindowManagerSupport.swift && git commit -m "refactor(state): extract WindowStateManager to eliminate global mutable state"`

---

### Task 2: 从 WindowManagerSupport 拆分 WindowFindingService — 窗口查找逻辑独立

**Depends on:** Task 1
**Files:**
- Create: `Sources/WindowFindingService.swift`
- Modify: `Sources/WindowManagerSupport.swift:20-460`（窗口查找相关方法）

**目标：** 将终端窗口查找逻辑从 1,882 行的 dumping ground 中提取为独立的 ~200 行模块。

- [ ] **Step 1: 创建 WindowFindingService — 封装所有窗口查找策略**

提取以下方法到新文件：
- `findWindowByTerminalContext(_:)` (WindowManagerSupport.swift:257-357)
- `findTerminalAppPID(from:)` (WindowManagerSupport.swift:360-384)
- `findWindowsForPID(_:)` (WindowManagerSupport.swift:386-421)
- `matchWindowByTTYProcess(tty:windows:)` (WindowManagerSupport.swift:423-453)
- `resolveTTY(forPID:)` (WindowManagerSupport.swift:455-480)
- `captureFocusedWindowIdentity()` (WindowManagerSupport.swift:48-103)

这些方法总行数约 250 行，提取后 WindowManagerSupport.swift 减少约 250 行。

新文件结构：
```swift
// Sources/WindowFindingService.swift
// 窗口查找：通过终端上下文、PID、TTY 精确匹配窗口
// 约 250 行
```

- [ ] **Step 2: 更新调用方 — ClaudeHookServer 和 WindowManager 引用新服务**

ClaudeHookServer.swift 中调用 `WindowManager.shared.findWindowByTerminalContext()` 改为 `WindowFindingService.shared.findWindowByTerminalContext()`。

如果不想新增 Singleton，也可以将 WindowFindingService 的方法作为 WindowManager 的计算属性代理调用。选择方案取决于是否需要独立测试。

- [ ] **Step 3: 验证构建**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 4: 提交**

Run: `git add Sources/WindowFindingService.swift Sources/WindowManagerSupport.swift Sources/ClaudeHookServer.swift && git commit -m "refactor(finding): extract WindowFindingService from WindowManagerSupport"`

---

### Task 3: 从 WindowManagerSupport 拆分 ScreenPositionService — 屏幕定位逻辑独立

**Depends on:** Task 1
**Files:**
- Create: `Sources/ScreenPositionService.swift`
- Modify: `Sources/WindowManagerSupport.swift:482-560,1021-1075,1718-1736`（屏幕检测和定位方法）

**目标：** 提取屏幕位置计算逻辑，与窗口查找、AX 操作分离。

- [ ] **Step 1: 创建 ScreenPositionService — 封装屏幕检测和 frame 计算**

提取以下方法：
- `isWindowOnMainScreen(windowID:)` (WindowManagerSupport.swift:482-541)
- `displayID(for:)` (WindowManagerSupport.swift:1021-1027)
- `displayIndex(forDisplayID:)` (WindowManagerSupport.swift:1029-1041)
- `displayContext(for:)` (WindowManagerSupport.swift:1042-1075)
- `axFrame(forVisibleFrameOf:)` (WindowManagerSupport.swift:1718-1728)
- `framesMatch(_:_:)` (WindowManagerSupport.swift:1730-1736)

总行数约 200 行。

- [ ] **Step 2: 验证构建**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 3: 提交**

Run: `git add Sources/ScreenPositionService.swift Sources/WindowManagerSupport.swift && git commit -m "refactor(screen): extract ScreenPositionService for display/frame logic"`

---

### Task 4: 从 WindowManagerSupport 拆分 SystemEventsFallback — AppleScript/JXA 后备独立

**Depends on:** Task 1
**Files:**
- Create: `Sources/SystemEventsFallback.swift`
- Modify: `Sources/WindowManagerSupport.swift:1077-1380`（System Events 相关方法）

**目标：** 将 System Events / JXA 后备机制独立为模块，与主路径 AX 操作分离。

- [ ] **Step 1: 创建 SystemEventsFallback — 封装所有 JXA/System Events 操作**

提取以下方法：
- `moveToMainScreenViaSystemEvents()` (WindowManagerSupport.swift:1077-1130)
- `restoreViaSystemEvents()` (WindowManagerSupport.swift:1132-1199)
- `shouldRestoreCurrentWindowViaSystemEvents()` (WindowManagerSupport.swift:1201-1254)
- `systemEventsSnapshot(forPID:)` (WindowManagerSupport.swift:1256-1295)
- `systemEventsGetWindowID(forPID:)` (WindowManagerSupport.swift:1297-1317)
- `systemEventsApply(frame:toPID:)` (WindowManagerSupport.swift:1319-1346)
- `runJXAScript(_:)` (WindowManagerSupport.swift:1392-1426)

总行数约 300 行。

- [ ] **Step 2: 验证构建**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 3: 提交**

Run: `git add Sources/SystemEventsFallback.swift Sources/WindowManagerSupport.swift && git commit -m "refactor(fallback): extract SystemEventsFallback for JXA/AppleScript operations"`

---

### Task 5: 从 ClaudeHookServer 拆分 HookEventHandler — 各 hook 事件独立处理

**Depends on:** Task 1
**Files:**
- Create: `Sources/HookEventHandler.swift`
- Modify: `Sources/ClaudeHookServer.swift:298-707`（4 个 handle 方法 + performRestore）

**目标：** 将 4 种 hook 事件处理逻辑从 HTTP 服务层分离，ClaudeHookServer 只负责 HTTP 路由。

- [ ] **Step 1: 创建 HookEventHandler — 封装 SessionStart/PromptSubmit/Stop/WindowMove 处理逻辑**

提取以下方法：
- `handleSessionStart(payload:headers:)` (ClaudeHookServer.swift:298-375)
- `handleUserPromptSubmit(payload:headers:)` (ClaudeHookServer.swift:377-537)
- `handleStop(payload:headers:)` (ClaudeHookServer.swift:580-635)
- `handleWindowMoveTrigger(payload:headers:)` (ClaudeHookServer.swift:637-707)
- `performRestore(binding:sessionID:)` (ClaudeHookServer.swift:539-578)

加上 `lastActivityBySession` 和 `stopDebounceInterval` 属性。

总行数约 420 行。

- [ ] **Step 2: 精简 ClaudeHookServer — 只保留 HTTP 服务和路由**

ClaudeHookServer.swift 从 904 行精简为约 200 行，只包含：
- `applyPreferences()` — 配置应用
- `stop()` — 服务停止
- `startIfNeeded()` — HTTP 服务启动
- `handleHookRequest()` — 请求分发（调用 HookEventHandler）
- Response helpers

- [ ] **Step 3: 验证构建**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 4: 提交**

Run: `git add Sources/HookEventHandler.swift Sources/ClaudeHookServer.swift && git commit -m "refactor(hook): extract HookEventHandler, slim ClaudeHookServer to HTTP routing only"`

---

### Task 6: 拆分 WindowManager 的超长函数 — restore 和 applySpaceStrategyForRestore

**Depends on:** Task 1
**Files:**
- Modify: `Sources/WindowManager.swift:371-693`（restore 函数，322 行）
- Modify: `Sources/WindowManager.swift:1148-1518`（applySpaceStrategyForRestore 函数，370 行）

**目标：** 将 2 个超长函数各拆为 3-4 个子函数，每个子函数不超过 80 行。

- [ ] **Step 1: 拆分 restore() 为子函数**

322 行的 `restore()` 应拆为：
- `restore(operationID:triggerSource:)` — 入口，约 30 行，调用子函数
- `performRestoreOperation(token:operationID:)` — 执行恢复，约 80 行
- `validateRestoreContext(operationID:)` — 验证恢复上下文，约 40 行
- `logRestoreResult(success:durationMs:operationID:)` — 记录结果，约 30 行

- [ ] **Step 2: 拆分 applySpaceStrategyForRestore() 为子函数**

370 行的 `applySpaceStrategyForRestore()` 应拆为：
- `applySpaceStrategyForRestore(windowID:operationID:)` — 入口，约 30 行，选择策略
- `applyYabaiStrategy(windowID:operationID:)` — yabai 策略，约 80 行
- `applyNativeSpaceStrategy(windowID:operationID:)` — 原生 Space 策略，约 80 行
- `applyDirectFrameRestore(windowID:operationID:)` — 直接 frame 恢复，约 50 行

- [ ] **Step 3: 验证构建**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 4: 提交**

Run: `git add Sources/WindowManager.swift && git commit -m "refactor(window): split restore() and applySpaceStrategyForRestore() into focused sub-functions"`

---

### Task 7: 清理死代码和未使用的函数

**Depends on:** Task 2, Task 3, Task 4
**Files:**
- Modify: `Sources/WindowManager.swift`（删除 `findStateByFallbackMatching` 死代码）
- Modify: `Sources/WindowManagerSupport.swift`（确认无残留死代码）

**目标：** 完成所有拆分后，删除不再被引用的函数和变量。

- [ ] **Step 1: 审计并删除 WindowManager.swift 中的死代码**

已知的死代码：
- `findStateByFallbackMatching()` (WindowManager.swift:894-950) — 已无调用者
- 检查是否有其他未引用的 private 函数

- [ ] **Step 2: 审计并删除 WindowManagerSupport.swift 中的死代码**

Task 2-4 拆分后，检查是否有残留的未引用方法。

- [ ] **Step 3: 验证构建 + 部署**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5 && bash scripts/dev-build.sh`
Expected:
  - Exit code: 0
  - Output contains: "✅ 构建成功！"

- [ ] **Step 4: 提交**

Run: `git add -A Sources/ && git commit -m "chore(cleanup): remove dead code after refactoring"`

---

## 重构后的目标文件结构

| 文件 | 预计行数 | 职责 |
|------|---------|------|
| WindowManager.swift | ~400 | toggle/moveToMainScreen 入口 + AX 操作 |
| WindowStateManager.swift | ~200 | 状态持久化 + 操作上下文 |
| WindowFindingService.swift | ~250 | 终端窗口查找（PID/TTY 精确匹配） |
| ScreenPositionService.swift | ~200 | 屏幕检测 + frame 计算 |
| SystemEventsFallback.swift | ~300 | JXA/AppleScript 后备操作 |
| HookEventHandler.swift | ~420 | 4 种 hook 事件处理 |
| ClaudeHookServer.swift | ~200 | HTTP 服务 + 路由分发 |
| SpaceController.swift | ~400×4 | Space 管理（可后续拆分） |

## 执行顺序图

```
Task 1: WindowStateManager (基础 — 消除全局状态)
  ├── Task 2: WindowFindingService (依赖 Task 1)
  ├── Task 3: ScreenPositionService (依赖 Task 1)
  ├── Task 4: SystemEventsFallback (依赖 Task 1)
  ├── Task 5: HookEventHandler (依赖 Task 1)
  └── Task 6: 拆分超长函数 (依赖 Task 1)
       └── Task 7: 清理死代码 (依赖 Task 2-4)
```
