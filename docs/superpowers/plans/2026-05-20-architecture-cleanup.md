# VibeFocus 架构清理重构计划

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 系统性清理 toggle/restore 系统的架构债务，消除状态双写、职责不清、代码重复三大类问题，使 bug 不再反复出现

**Architecture:** 
- 数据流：Hook事件 → SessionWindowRegistry → ToggleEngine(唯一restore入口) → SpaceController + WindowManager
- 关键组件：统一YabaiClient、统一TerminalRegistry、拆分WindowManager为WindowFinder+WindowMover+AXBridge、统一ToggleRecord存储
- 设计理由：当前的核心问题是"改一个地方漏改另一个地方"，根因是同一份数据存两处、同一逻辑写两遍。重构以"单一事实来源"为原则

**Tech Stack:** Swift 5.9, macOS 14+, yabai (scripting addition + CLI), SQLite3, CGEvent/AXUIElement

**Scope:** Large
**Risk:** High
**Risks:**
- Task 1-3 是基础设施，后续所有 Task 依赖它们，必须先完成
- WindowManager 拆分涉及 14 个文件 2587 行，改动面最大 — 必须分步进行，每步验证编译通过
- ToggleEngine + SessionWindowRegistry 统一是最容易出问题的环节 — 两套存储合并时数据可能丢失
- yabai SA 不可用时所有 space 操作走 CGEvent fallback，重构不能破坏这条路径

**Autonomy Level:** Guided — 每个 Task 完成后输出进度摘要

---

## 前置调研摘要（已完成的代码审计）

### 核心问题清单

| # | 问题 | 严重度 | 影响范围 |
|---|------|--------|---------|
| P1 | Toggle 状态双写：WindowState.toggleFields + toggle_records 表 | 严重 | 所有 restore 路径 |
| P2 | Restore 代码三条路径：WindowManager.restore / ToggleEngine.restore / HookEventHandler 内联逻辑 | 严重 | 所有 restore 路径 |
| P3 | Terminal app 列表四份拷贝 | 中等 | 窗口识别、badge、title editor |
| P4 | Yabai 客户端散布在 Overlay 和 Space 模块 | 中等 | space 查询、overlay 刷新 |
| P5 | WindowManager 是 God Object (2587行14文件) | 严重 | 所有窗口操作 |
| P6 | Preferences 四种持久化模式 | 中等 | 设置变更不持久 |
| P7 | `nonisolated(unsafe)` 线程安全问题 | 低 | 并发场景 |
| P8 | SpaceController 有 312 行 Recovery 代码 | 中等 | space 切换可靠性 |
| P9 | `AppVersion.current` 硬编码 | 低 | 版本号漂移 |
| P10 | HookEventHandler.handleUserPromptSubmit 337行单函数 | 严重 | 可读性、可维护性 |

### Singleton 依赖图

```
HookEventHandler → WindowManager → SessionWindowRegistry → WindowStateStore
                → ToggleEngine → WindowManager
                              → SessionWindowRegistry
                              → SpaceController
HotKeyManager → WindowManager
```

---

### Task 1: 创建 TerminalRegistry — 统一终端应用识别

**Depends on:** None
**Files:**
- Create: `Sources/Support/TerminalRegistry.swift`
- Modify: `Sources/Hook/TerminalAppRegistry.swift` (删除，内容迁移)
- Modify: `Sources/TitleEditor/TitleEditorService.swift:9-19` (删除重复列表，引用 TerminalRegistry)
- Modify: `Sources/App/DockBadgeManager.swift:10-14` (删除重复列表，引用 TerminalRegistry)
- Modify: `Sources/Hook/HookEventHandler+WindowMove.swift:81-82` (删除重复列表，引用 TerminalRegistry)

- [ ] **Step 1: 创建 TerminalRegistry**

```swift
// Sources/Support/TerminalRegistry.swift

enum TerminalRegistry {
    struct AppDef {
        let bundleID: String
        let name: String
    }

    static let terminals: [AppDef] = [
        AppDef(bundleID: "com.googlecode.iterm2", name: "iTerm2"),
        AppDef(bundleID: "com.apple.Terminal", name: "Terminal"),
        AppDef(bundleID: "io.alacritty", name: "Alacritty"),
        AppDef(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code"),
        AppDef(bundleID: "com.electron.hyper", name: "Hyper"),
        AppDef(bundleID: "org.tabby", name: "Tabby"),
        AppDef(bundleID: "com.kitty", name: "kitty"),
    ]

    static let ides: [AppDef] = [
        AppDef(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code"),
        AppDef(bundleID: "com.apple.dt.Xcode", name: "Xcode"),
    ]

    static var terminalBundleIDs: [String] { terminals.map(\.bundleID) }
    static var terminalAppNames: [String] { terminals.map(\.name) }
    static var ideBundleIDs: [String] { ides.map(\.bundleID) }
    static var ideAppNames: [String] { ides.map(\.name) }

    static func isTerminalPID(_ pid: pid_t) -> Bool {
        guard let bundleID = bundleID(for: pid) else { return false }
        return terminalBundleIDs.contains(bundleID)
    }

    static func bundleID(for pid: pid_t) -> String? {
        let app = NSRunningApplication(processIdentifier: pid)
        return app?.bundleIdentifier
    }
}
```

- [ ] **Step 2: 修改 TitleEditorService — 删除重复的终端列表**

文件: `Sources/TitleEditor/TitleEditorService.swift:9-19`

删除 `terminalBundleIDs` 静态数组，替换所有引用为 `TerminalRegistry.terminalBundleIDs`。

- [ ] **Step 3: 修改 DockBadgeManager — 删除重复的终端列表**

文件: `Sources/App/DockBadgeManager.swift:10-14`

删除 `terminalBundleIDs` 静态数组，替换所有引用为 `TerminalRegistry.terminalBundleIDs`。

- [ ] **Step 4: 修改 HookEventHandler+WindowMove — 删除重复的 IDE 列表**

文件: `Sources/Hook/HookEventHandler+WindowMove.swift:81-82`

删除 `ideAppNames` 和 `ideBundleIDs` 静态数组，替换所有引用为 `TerminalRegistry.ideAppNames` / `TerminalRegistry.ideBundleIDs`。

- [ ] **Step 5: 修改 TerminalAppRegistry — 委托到 TerminalRegistry**

文件: `Sources/Hook/TerminalAppRegistry.swift`

将 `TerminalAppRegistry` 的所有函数体改为委托调用 `TerminalRegistry`。保持 API 不变避免大范围改动。

- [ ] **Step 6: 验证编译**
Run: `swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 7: 质量门禁**
Run: `swift build 2>&1 | grep -c error`
Expected: 0

- [ ] **Step 8: 提交**
Run: `git add -A && git commit -m "refactor(support): create TerminalRegistry as single source of truth for terminal/IDE app identification"`

---

### Task 2: 创建 YabaiClient — 统一 yabai 进程调用

**Depends on:** None
**Files:**
- Create: `Sources/Space/YabaiClient.swift`
- Modify: `Sources/Space/SpaceController.swift` (替换 runYabai 调用)
- Modify: `Sources/Overlay/ScreenOverlayManager.swift` (替换直接 Process 调用)

- [ ] **Step 1: 创建 YabaiClient**

```swift
// Sources/Space/YabaiClient.swift

@MainActor
final class YabaiClient {
    static let shared = YabaiClient()

    private var cachedPath: String?
    private let commandTimeout: TimeInterval = 2.0

    private init() {}

    func yabaiPath() -> String? {
        if let cached = cachedPath, FileManager.default.fileExists(atPath: cached) {
            return cached
        }
        let candidates = [
            "/opt/homebrew/bin/yabai",
            "/usr/local/bin/yabai",
            "/usr/bin/yabai",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                cachedPath = path
                return path
            }
        }
        return nil
    }

    struct YabaiResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    func run(arguments: [String], operationID: String? = nil) -> YabaiResult? {
        guard let path = yabaiPath() else { return nil }
        let task = Process()
        task.launchPath = path
        task.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
            let sem = DispatchSemaphore(value: 0)
            task.terminationHandler = { _ in sem.signal() }
            let result = sem.wait(timeout: .now() + commandTimeout)
            if result == .timedOut {
                task.terminate()
                return nil
            }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            return YabaiResult(
                exitCode: task.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return nil
        }
    }

    func queryJSON<T: Decodable>(_ type: T.Type, arguments: [String]) -> T? {
        guard let result = run(arguments: arguments), result.exitCode == 0 else { return nil }
        return try? JSONDecoder().decode(type, from: Data(result.stdout.utf8))
    }

    func querySpaces() -> [YabaiSpaceInfo]? {
        queryJSON([YabaiSpaceInfo].self, arguments: ["-m", "query", "--spaces"])
    }

    func queryWindows() -> [YabaiWindowInfo]? {
        queryJSON([YabaiWindowInfo].self, arguments: ["-m", "query", "--windows"])
    }

    func queryWindow(windowID: UInt32) -> YabaiWindowInfo? {
        queryJSON(YabaiWindowInfo.self, arguments: ["-m", "query", "--windows", "--window", String(windowID)])
    }

    func queryDisplays() -> [YabaiDisplayInfo]? {
        queryJSON([YabaiDisplayInfo].self, arguments: ["-m", "query", "--displays"])
    }

    func queryDisplay(index: Int) -> YabaiDisplayInfo? {
        queryJSON(YabaiDisplayInfo.self, arguments: ["-m", "query", "--displays", "--display", String(index)])
    }

    func queryFocusedSpace() -> YabaiSpaceInfo? {
        queryJSON(YabaiSpaceInfo.self, arguments: ["-m", "query", "--spaces", "--space"])
    }
}
```

- [ ] **Step 2: 修改 SpaceController — 委托到 YabaiClient**

文件: `Sources/Space/SpaceController.swift`

将 `runYabai()` 和 `decodeSingleOrFirst` 等辅助方法改为调用 `YabaiClient.shared`。保持现有 `querySpaces()` / `queryWindow()` 等公共 API 不变，内部委托。

- [ ] **Step 3: 修改 ScreenOverlayManager — 替换 Process 调用**

文件: `Sources/Overlay/ScreenOverlayManager.swift` 和相关 extension

将 `getYabaiPath()`, `queryYabaiSpaces()`, `queryFocusedSpaceIndex()`, `getYabaiDisplayIndex()` 改为调用 `YabaiClient.shared`。

- [ ] **Step 4: 验证编译**
Run: `swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 5: 质量门禁**
Run: `swift build 2>&1 | grep -c error`
Expected: 0

- [ ] **Step 6: 提交**
Run: `git add -A && git commit -m "refactor(space): create YabaiClient as single yabai process abstraction"`

---

### Task 3: 统一 Toggle 状态存储 — 消除双写

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/ClaudeHookModels.swift` (WindowState 中的 toggle 字段标记 deprecated)
- Modify: `Sources/Window/WindowStateStore+ToggleRecord.swift` (成为唯一 toggle 持久化路径)
- Modify: `Sources/Window/WindowStateStore+Bindings.swift` (移除 toggle 字段的 SQL 列)
- Modify: `Sources/Hook/SessionWindowRegistry.swift` (updateToggleState / clearToggleState 委托到 WindowStateStore)

- [ ] **Step 1: 审计所有 toggle 状态读写点**

通过 grep 找出所有读写 `toggleToggledAt`、`toggleReason`、`origX/Y/W/H`、`targetX/Y/W/H`、`sourceSpace` 等 toggle 字段的位置。列出每个读写点和它操作的存储（WindowState vs toggle_records）。

- [ ] **Step 2: 确认 ToggleRecord 是完整的事实来源**

验证 `WindowStateStore+ToggleRecord` 的 `saveToggleRecord()` 保存了所有 restore 需要的字段：`windowID, pid, bundleID, appName, origFrame, targetFrame, sourceSpace, sourceYabaiDisp, sourceDispSpace`。如果缺少字段，补充。

- [ ] **Step 3: SessionWindowRegistry.updateToggleState 改为写 toggle_records**

文件: `Sources/Hook/SessionWindowRegistry.swift`

`updateToggleState(windowID:toggleUpdater:)` 当前修改 `WindowState` 的 toggle 字段。改为调用 `WindowStateStore.shared.saveToggleRecord()`。保持 `clearToggleState()` 也清理 toggle_records。

- [ ] **Step 4: SessionWindowRegistry.clearToggleState 改为清理 toggle_records**

文件: `Sources/Hook/SessionWindowRegistry.swift`

`clearToggleState(windowID:)` 改为调用 `WindowStateStore.shared.clearToggleRecord(windowID:)`。

- [ ] **Step 5: 验证所有 restore 路径都从 toggle_records 读取**

确认 `ToggleEngine.restore()` 只从 `WindowStateStore.shared.loadToggleRecord()` 读取，不再读取 `WindowState.toggleFields`。

- [ ] **Step 6: 验证编译 + 功能**
Run: `swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 7: 质量门禁**
Run: `swift build 2>&1 | grep -c error`
Expected: 0

- [ ] **Step 8: 提交**
Run: `git add -A && git commit -m "refactor(toggle): unify toggle state storage to toggle_records table only"`

---

### Task 4: 统一 Restore 入口 — 消除三条 restore 路径

**Depends on:** Task 3
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift` (成为唯一 restore 入口)
- Modify: `Sources/Window/WindowManager+Restore.swift` (删除，逻辑迁入 ToggleEngine)
- Modify: `Sources/Window/WindowManager+Toggle.swift` (调用 ToggleEngine 而非自己的 restore 逻辑)
- Modify: `Sources/Hook/HookEventHandler.swift` (handleUserPromptSubmit 调用 ToggleEngine.restore 而非内联逻辑)

- [ ] **Step 1: 审计 WindowManager+Restore.swift 的所有功能**

读文件，列出每个函数及其调用者。确认哪些逻辑是 ToggleEngine.restore() 缺少的。

- [ ] **Step 2: 将 WindowManager+Restore 的前置验证迁入 ToggleEngine.restore**

文件: `Sources/Toggle/ToggleEngine.swift`

`WindowManager+Restore` 有前置验证（检查窗口是否在主屏、检查 toggle record 是否存在）。将这些验证作为 `ToggleEngine.restore()` 的前置步骤。

- [ ] **Step 3: HookEventHandler.handleUserPromptSubmit 调用 ToggleEngine.restore**

文件: `Sources/Hook/HookEventHandler.swift:145-482`

将 `handleUserPromptSubmit` 中的内联 restore 逻辑替换为单行调用 `ToggleEngine.shared.restore(windowID:fallbackPID:triggerSource:traceID:)`。保留窗口解析逻辑（因为 hook 事件需要从 sessionID 解析到 windowID），但 restore 本身委托出去。

- [ ] **Step 4: WindowManager.toggle() 中的 restore 路径也委托到 ToggleEngine**

文件: `Sources/Window/WindowManager+Toggle.swift`

当 `toggle()` 检测到窗口已在主屏（需要 restore）时，调用 `ToggleEngine.shared.restore()` 而非内联逻辑。

- [ ] **Step 5: 验证编译**
Run: `swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0

- [ ] **Step 6: 质量门禁**
Run: `swift build 2>&1 | grep -c error`
Expected: 0

- [ ] **Step 7: 提交**
Run: `git add -A && git commit -m "refactor(toggle): unify all restore paths through ToggleEngine.restore()"`

---

### Task 5: 拆分 WindowManager — 提取 WindowFinder 和 AXBridge

**Depends on:** Task 3, Task 4
**Files:**
- Create: `Sources/Window/WindowFinder.swift` (从 WindowManager+Finding.swift 和 WindowManager+TerminalContext.swift 提取)
- Create: `Sources/Window/AXBridge.swift` (从 WindowManager+AXHelpers.swift 提取)
- Modify: `Sources/Window/WindowManager.swift` (委托到新类)

- [ ] **Step 1: 创建 WindowFinder — 封装窗口查找逻辑**

从 `WindowManager+Finding.swift` (267行) 和 `WindowManager+TerminalContext.swift` (460行) 提取到 `WindowFinder`。

```swift
// Sources/Window/WindowFinder.swift
@MainActor
final class WindowFinder {
    static let shared = WindowFinder()

    func findByPID(_ pid: pid_t, windowID: UInt32? = nil) -> AXUIElement? { ... }
    func findByTerminalContext(_ ctx: TerminalContext) -> WindowIdentity? { ... }
    func findByCGWindowID(_ cgID: UInt32) -> AXUIElement? { ... }
    func focusedWindow(for pid: pid_t) -> AXUIElement? { ... }
}
```

- [ ] **Step 2: 创建 AXBridge — 封装 AX 操作**

从 `WindowManager+AXHelpers.swift` (343行) 提取到 `AXBridge`。

```swift
// Sources/Window/AXBridge.swift
@MainActor
enum AXBridge {
    func frame(of element: AXUIElement) -> CGRect? { ... }
    func apply(frame: CGRect, to element: AXUIElement, ...) -> Bool { ... }
    func title(of element: AXUIElement) -> String? { ... }
    func windowNumber(for element: AXUIElement) -> UInt32? { ... }
    func isAttributeSettable(_ element: AXUIElement, attribute: String) -> Bool { ... }
}
```

- [ ] **Step 3: WindowManager 委托到 WindowFinder 和 AXBridge**

文件: `Sources/Window/WindowManager.swift`

保留 `WindowManager.shared` 的公共 API，内部改为委托调用 `WindowFinder.shared` 和 `AXBridge`。保持向后兼容。

- [ ] **Step 4: 验证编译**
Run: `swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0

- [ ] **Step 5: 质量门禁**
Run: `swift build 2>&1 | grep -c error`
Expected: 0

- [ ] **Step 6: 提交**
Run: `git add -A && git commit -m "refactor(window): extract WindowFinder and AXBridge from WindowManager"`

---

### Task 6: 简化 HookEventHandler.handleUserPromptSubmit

**Depends on:** Task 4
**Files:**
- Modify: `Sources/Hook/HookEventHandler.swift:145-482`

- [ ] **Step 1: 将 handleUserPromptSubmit 拆分为 5 个子函数**

当前 337 行单函数拆为：
1. `resolveWindowIdentity(payload:traceID:) -> WindowIdentity?` — 解析窗口身份
2. `validateRestoreEligibility(identity:traceID:) -> Bool` — 验证是否应该 restore
3. `executeRestore(identity:traceID:) -> Bool` — 执行 restore（委托 ToggleEngine）
4. `cleanupAfterRestore(identity:traceID:success:)` — 清理状态
5. `handleUserPromptSubmit(payload:)` — 协调调用上面 4 个函数

- [ ] **Step 2: 验证编译**
Run: `swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0

- [ ] **Step 3: 质量门禁**
Run: `swift build 2>&1 | grep -c error`
Expected: 0

- [ ] **Step 4: 提交**
Run: `git add -A && git commit -m "refactor(hook): decompose handleUserPromptSubmit into focused sub-functions"`

---

### Task 7: 修复线程安全和持久化问题

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/ClaudeHookPreferences.swift` (修复 nonisolated(unsafe))
- Modify: `Sources/App/AppVersion.swift` (从 Info.plist 读取版本号)
- Modify: `Sources/Settings/SettingsUI.swift` (替换 @AppStorage 为 ClaudeHookPreferences 调用)

- [ ] **Step 1: 修复 ClaudeHookPreferences.lastInstallAt 线程安全问题**

文件: `Sources/Hook/ClaudeHookPreferences.swift:5`

将 `nonisolated(unsafe) static var lastInstallAt` 改为 `@MainActor static var lastInstallAt`，或使用 `UserDefaults.standard` 读取（UserDefaults 是线程安全的）。

- [ ] **Step 2: 修复 AppVersion.current 硬编码**

文件: `Sources/App/AppVersion.swift`

```swift
enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
```

- [ ] **Step 3: SettingsView 中的 @AppStorage 替换为 ClaudeHookPreferences 调用**

文件: `Sources/Settings/SettingsUI.swift`

将 `@AppStorage("hook_enabled")` 等替换为 `ClaudeHookPreferences.isEnabled` 等调用，确保 `PreferencesSync.persistToDisk()` 被正确调用。

- [ ] **Step 4: 验证编译**
Run: `swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0

- [ ] **Step 5: 质量门禁**
Run: `swift build 2>&1 | grep -c error`
Expected: 0

- [ ] **Step 6: 提交**
Run: `git add -A && git commit -m "fix: resolve thread-safety, hardcoded version, and preference persistence issues"`

---

## 执行顺序图

```
Task 1: TerminalRegistry  ─┐
Task 2: YabaiClient       ─┤─ 可并行
Task 3: 统一Toggle存储    ─┤─ 可并行
Task 7: 线程安全修复      ─┘─ 可并行
         │
Task 4: 统一Restore入口  ←── Task 3
         │
Task 5: 拆分WindowManager ←── Task 3, 4
         │
Task 6: 简化HookEventHandler ←── Task 4
```

## 验收标准

每个 Task 完成后必须满足：
1. `swift build` 零错误
2. `bash scripts/dev-build.sh` 构建签名 app 成功
3. 部署后 VibeFocus 正常启动（`ps aux | grep VibeFocus` 可见进程）
4. Ctrl+Q toggle 功能正常（手动验证）
5. UserPromptSubmit auto-restore 功能正常（手动验证）
6. Overlay 正常显示 space index
