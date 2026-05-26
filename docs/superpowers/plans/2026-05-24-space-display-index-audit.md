# Research + Refactor: Space/Display Index System Audit & Type Safety

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 调研并修复 space/display index 系统的类型安全问题 — 当前代码中有至少 6 种不同的索引/ID，全部用裸 `Int` 传递，参数名无法区分类型，是 bug 频发的根本原因。

**Architecture:** 已有 `DisplayIdentifier` 和 `SpaceIdentifier` 枚举定义但完全未使用。计划将其激活为 API 边界类型，所有 SpaceController 公共方法改为使用强类型参数，内部才转换为 yabai 命令需要的裸 Int。

**Scope:** Medium (7 files)
**Risk:** Medium (修改 SpaceController API 面，影响 ToggleEngine/WindowManager 等消费者)

**Risks:**
- Task 1-2 修改 SpaceController API 签名 — 所有调用方需同步更新 → 缓解：分两步，先改 SpaceController 再改消费者
- Task 3 修改 ToggleRecord — 需要数据库迁移 → 缓解：SQLite 字段名不变，只改 Swift 侧类型

**Autonomy Level:** Full

---

## 调研报告：Space/Display Index 系统混乱的根因分析

### 1. 现有索引系统清单（6 种）

| ID | 名称 | 来源 | 类型 | 例子 |
|----|------|------|------|------|
| A | yabai global space index | `yabai -m query --spaces` → `.index` | 1-based Int | 主屏 space1-3, 副屏 space4-6 |
| B | yabai display index | `yabai -m query --spaces` → `.display` | 1-based Int | 1=主屏, 2=副屏 |
| C | display-local space index | `displayLocalSpaceIndex()` 计算 | 1-based Int | 副屏第2个 space = 2 |
| D | macOS native space ID | `yabai -m query --spaces` → `.id` | Int64 (CGS) | 0x7F... |
| E | NSScreen array index | `NSScreen.screens.enumerated()` | 0-based Int | 0=主屏, 1=副屏 |
| F | CGDirectDisplayID | `NSScreen.cgDirectDisplayID` | UInt32 | 0x12345678 |

### 2. 核心问题：所有索引用裸 Int 传递

**文件 `Sources/Space/SpaceController.swift:46-51`：**
```swift
struct SpaceContext {
    let sourceSpaceIndex: Int?      // 实际是 yabai global (A)
    let targetSpaceIndex: Int?      // 实际是 yabai global (A)
    let sourceDisplayIndex: Int?    // 实际是 yabai display (B)
    let sourceDisplaySpaceIndex: Int? // 实际是 display-local (C)
}
```
四个字段全是 `Int?`，命名无法区分类型。`sourceDisplayIndex` 是 yabai 还是 NSScreen？只能读代码才能确认。

### 3. ToggleRecord 混用多种索引

**文件 `Sources/Hook/ClaudeHookModels.swift:122-134`：**
```swift
struct ToggleRecord {
    let sourceSpace: Int          // yabai global space index (A)
    let sourceDisplay: Int        // NSScreen array index (E) ← !
    let sourceYabaiDisp: Int      // yabai display index (B)
    let sourceDispSpace: Int      // display-local space index (C)
}
```

`sourceDisplay` 是 NSScreen index (E)，而 `sourceYabaiDisp` 是 yabai display index (B)。两个都叫 "display" 但完全不同的东西。

### 4. save 路径的 fallback 混合索引

**文件 `Sources/Window/WindowManager+MoveWindow.swift:282`：**
```swift
let teSourceDisplay = spaceContext.sourceDisplayIndex ?? sourceContext.index ?? 0
```
- `spaceContext.sourceDisplayIndex` = yabai display index (B)
- `sourceContext.index` = NSScreen array index (E)
- fallback = 0（既不是 yabai 也不是 NSScreen 的有效值）

两个不同索引系统做 `??` fallback，语义完全不同。

### 5. DisplayIdentifier/SpaceIdentifier 已定义但零使用

**文件 `Sources/Space/CoordinateKit.swift:11-41`：**
```swift
enum DisplayIdentifier { case yabaiIndex(Int); case screenArrayIndex(Int); case cgDirectDisplayID(UInt32) }
enum SpaceIdentifier { case yabaiIndex(Int); case nativeID(Int64) }
```
搜索全代码库：这两个枚举在 CoordinateKit.swift 之外 **没有任何引用**。死代码。

### 6. 已因索引混淆导致的 bug 记录

- `project_space_restore_bug.md`: yabai SA 失败时 restore 到错误 space
- `space_switch_regression.md`: 工作区切换回归问题
- git log 中多个 "wrong space" / "wrong display" 相关的修复

---

## Task 1: Activate DisplayIdentifier in SpaceContext and SpaceController public API

**Depends on:** None
**Files:**
- Modify: `Sources/Space/CoordinateKit.swift` (extend DisplayIdentifier with helpers)
- Modify: `Sources/Space/SpaceController.swift` (SpaceContext uses strong types)
- Modify: `Sources/Space/SpaceController+Context.swift` (captureSpaceContext returns strong types)
- Modify: `Sources/Space/SpaceController+Query.swift` (query functions return strong types)
- Modify: `Sources/Space/SpaceController+Switch.swift` (switchDisplayToSpace uses strong types)
- Modify: `Sources/Space/SpaceController+Move.swift` (moveWindow uses strong types)

- [ ] **Step 1: 扩展 DisplayIdentifier 和 SpaceIdentifier — 添加便捷方法和转换**

文件: `Sources/Space/CoordinateKit.swift`（在 `SpaceIdentifier` 定义之后，`QuartzRect` 之前插入）

```swift
// MARK: - DisplayIdentifier Helpers

extension DisplayIdentifier {
    /// yabai display index (1-based)，如果不是 yabai 类型返回 nil
    var yabaiIndex: Int? {
        if case .yabaiIndex(let i) = self { return i }
        return nil
    }

    /// 从 yabai display index 创建
    static func yabai(_ index: Int) -> DisplayIdentifier { .yabaiIndex(index) }

    /// 从 NSScreen array index 创建
    static func screenArray(_ index: Int) -> DisplayIdentifier { .screenArrayIndex(index) }

    /// 从 CGDirectDisplayID 创建
    static func cgDisplay(_ id: UInt32) -> DisplayIdentifier { .cgDirectDisplayID(id) }
}

// MARK: - SpaceIdentifier Helpers

extension SpaceIdentifier {
    /// yabai global space index (1-based)，如果不是 yabai 类型返回 nil
    var yabaiIndex: Int? {
        if case .yabaiIndex(let i) = self { return i }
        return nil
    }

    /// 从 yabai global space index 创建
    static func yabai(_ index: Int) -> SpaceIdentifier { .yabaiIndex(index) }

    /// 从 macOS native space ID 创建
    static func native(_ id: Int64) -> SpaceIdentifier { .nativeID(id) }
}
```

- [ ] **Step 2: 修改 SpaceContext 使用强类型**

文件: `Sources/Space/SpaceController.swift:46-51`（替换 SpaceContext 结构体）

```swift
struct SpaceContext {
    /// 窗口所在的 yabai 全局 space index
    let sourceSpaceIndex: SpaceIdentifier?
    /// 目标显示器上当前可见的 yabai 全局 space index
    let targetSpaceIndex: SpaceIdentifier?
    /// 窗口所在的 yabai display index (1-based, 1=主屏)
    let sourceDisplayIndex: DisplayIdentifier?
    /// 窗口在其所在显示器上的 display-local space index (1-based)
    let sourceDisplaySpaceIndex: Int?
}
```

- [ ] **Step 3: 修改 captureSpaceContext 返回强类型**

文件: `Sources/Space/SpaceController+Context.swift:7-54`（替换 captureSpaceContext 函数）

```swift
    func captureSpaceContext(windowID: UInt32, operationID: String? = nil) -> SpaceContext {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return SpaceContext(
                sourceSpaceIndex: nil,
                targetSpaceIndex: nil,
                sourceDisplayIndex: nil,
                sourceDisplaySpaceIndex: nil
            )
        }

        let windowInfo = queryWindow(windowID: windowID)
        let windowSpace = windowInfo?.space
        let windowDisplay = windowInfo?.display
        let spaces = querySpaces()
        let visibleSpaceOnDisplay = visibleSpaceIndex(forDisplayIndex: windowDisplay, spaces: spaces)
        let sourceSpace = preferredSourceSpace(
            windowSpace: windowSpace,
            visibleSpace: visibleSpaceOnDisplay,
            fallbackSpace: nil
        )
        let localSpace = displayLocalSpaceIndex(
            forGlobalSpaceIndex: sourceSpace,
            displayIndex: windowDisplay,
            spaces: spaces
        )

        log(
            "[SpaceController] capture space context",
            fields: [
                "op": op,
                "windowID": String(windowID),
                "sourceSpace": String(describing: sourceSpace),
                "windowSpace": String(describing: windowSpace),
                "visibleSpace": String(describing: visibleSpaceOnDisplay),
                "display": String(describing: windowDisplay),
                "localSpace": String(describing: localSpace)
            ]
        )

        return SpaceContext(
            sourceSpaceIndex: sourceSpace.map { .yabai($0) },
            targetSpaceIndex: visibleSpaceOnDisplay.map { .yabai($0) },
            sourceDisplayIndex: windowDisplay.map { .yabai($0) },
            sourceDisplaySpaceIndex: localSpace
        )
    }
```

- [ ] **Step 4: 修改 switchDisplayToSpace 使用 SpaceIdentifier**

文件: `Sources/Space/SpaceController+Switch.swift:7`（修改函数签名，内部提取裸 Int）

替换函数签名和开头的变量赋值：

```swift
    func switchDisplayToSpace(targetSpace: SpaceIdentifier, operationID: String?) -> Bool {
        let op = operationID ?? "none"
        guard let targetSpaceIndex = targetSpace.yabaiIndex else {
            log("[SpaceController] switchDisplayToSpace: unsupported space identifier type", level: .warn, fields: ["op": op])
            return false
        }
        refreshAvailabilityIfNeeded()
```

同时把函数体中所有 `targetSpace` 引用改为 `targetSpaceIndex`（保持裸 Int 传给 yabai 命令）。注意：函数内部用 `targetSpaceIndex` 作为裸 Int 传给 yabai 命令参数，`targetSpace` 是入参保持强类型。

- [ ] **Step 5: 修改 moveWindow 使用 SpaceIdentifier**

文件: `Sources/Space/SpaceController+Move.swift:7`（修改函数签名）

```swift
    func moveWindow(_ windowID: UInt32, toSpace: SpaceIdentifier, focus: Bool, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        guard let spaceIndex = toSpace.yabaiIndex else {
            log("[SpaceController] moveWindow: unsupported space identifier type", level: .warn, fields: ["op": op])
            return false
        }
```

函数体中 `spaceIndex` 替代原 `spaceIndex` 参数，其余 yabai 命令调用不变。

- [ ] **Step 6: 修改 query 函数返回强类型**

文件: `Sources/Space/SpaceController+Query.swift:87-101`

```swift
    func windowSpaceIndex(windowID: UInt32) -> SpaceIdentifier? {
        refreshAvailabilityIfNeeded()
        guard isEnabled, let window = queryWindow(windowID: windowID) else {
            return nil
        }
        return window.space.map { .yabai($0) }
    }

    func windowDisplayIndex(windowID: UInt32) -> DisplayIdentifier? {
        refreshAvailabilityIfNeeded()
        guard isEnabled, let window = queryWindow(windowID: windowID) else {
            return nil
        }
        return window.display.map { .yabai($0) }
    }
```

`displayVisibleSpace` 同理改为返回 `SpaceIdentifier?`：
```swift
    func displayVisibleSpace(displayIndex: DisplayIdentifier?) -> SpaceIdentifier? {
        guard let idx = displayIndex?.yabaiIndex else { return nil }
        let resolvedSpaces = querySpaces()
        return resolvedSpaces?.first(where: { $0.display == idx && $0.isVisible == true })?.index.map { .yabai($0) }
    }
```

- [ ] **Step 7: 验证编译**
Run: `swift build 2>&1 | tail -10`
Expected:
  - 编译错误仅在消费者文件中（ToggleEngine+Restore, WindowManager+MoveWindow 等）
  - 这些将在 Task 2 中修复

- [ ] **Step 8: 提交**
Run: `git add Sources/Space/ && git commit -m "refactor(space): activate DisplayIdentifier/SpaceIdentifier in SpaceController API"`

---

### Task 2: Update all SpaceController consumers to use strong types

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Toggle/ToggleEngine+Restore.swift`
- Modify: `Sources/Toggle/ToggleEngine.swift`
- Modify: `Sources/Window/WindowManager+MoveWindow.swift`
- Modify: `Sources/Toggle/ShutdownSnapshotManager.swift`
- Modify: `Sources/Toggle/TerminalRestoreService.swift`

- [ ] **Step 1: 更新 ToggleEngine.save 使用强类型**

文件: `Sources/Toggle/ToggleEngine.swift:27-39`

ToggleRecord 本身暂时保持裸 Int（数据库兼容），但 save 接口改为接受强类型：

```swift
    func save(
        windowID: UInt32,
        pid: Int32,
        bundleIdentifier: String?,
        appName: String?,
        origFrame: CGRect,
        sourceSpace: SpaceIdentifier,
        sourceDisplay: DisplayIdentifier,
        sourceYabaiDisp: DisplayIdentifier,
        sourceDispSpace: Int,
        targetFrame: CGRect,
        targetDisplay: Int,
        sessionID: String?
    ) {
```

在构造 ToggleRecord 时提取裸值：
```swift
        let record = ToggleRecord(
            windowID: windowID,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            origFrame: origFrame,
            sourceSpace: sourceSpace.yabaiIndex ?? 0,
            sourceDisplay: sourceDisplay.yabaiIndex ?? 0,  // 注意：这里可能需要区分 NSScreen vs yabai
            sourceYabaiDisp: sourceYabaiDisp.yabaiIndex ?? 0,
            sourceDispSpace: sourceDispSpace,
            targetFrame: targetFrame,
            targetDisplay: targetDisplay,
            toggledAt: Date(),
            sessionID: sessionID
        )
```

**关键发现：** `sourceDisplay` 在 ToggleRecord 中实际存的是 NSScreen index，不是 yabai display index。save 调用方（WindowManager+MoveWindow.swift:282）的 `teSourceDisplay = spaceContext.sourceDisplayIndex ?? sourceContext.index ?? 0` 混合了两种索引。修复方案：ToggleRecord.sourceDisplay 改为明确存 yabai display index，统一语义。

- [ ] **Step 2: 更新 ToggleEngine+Restore 中的 SpaceController 调用**

文件: `Sources/Toggle/ToggleEngine+Restore.swift`

所有 `spaceController.switchDisplayToSpace(targetSpace: Int, ...)` 改为 `spaceController.switchDisplayToSpace(targetSpace: .yabai(Int), ...)`
所有 `spaceController.moveWindow(windowID, toSpaceIndex: Int, ...)` 改为 `spaceController.moveWindow(windowID, toSpace: .yabai(Int), ...)`
所有 `spaceController.windowSpaceIndex(windowID:)` 返回值使用 `.yabaiIndex` 提取
所有 `spaceController.displayVisibleSpace(displayIndex: Int?)` 改为传入 `.yabai(Int?)`

- [ ] **Step 3: 更新 WindowManager+MoveWindow 中的 save 调用**

文件: `Sources/Window/WindowManager+MoveWindow.swift:297-310`

将裸 Int 参数替换为从 SpaceContext 提取的强类型值：

```swift
            ToggleEngine.shared.save(
                windowID: postMoveWindowID,
                pid: identity.pid,
                bundleIdentifier: identity.bundleIdentifier,
                appName: identity.appName,
                origFrame: origFrame,
                sourceSpace: spaceContext.sourceSpaceIndex ?? .yabai(sourceSpaceIndex),
                sourceDisplay: spaceContext.sourceDisplayIndex ?? .screenArray(sourceContext.index ?? 0),
                sourceYabaiDisp: spaceContext.sourceDisplayIndex ?? .yabai(0),
                sourceDispSpace: spaceContext.sourceDisplaySpaceIndex ?? 0,
                targetFrame: actualTargetFrame,
                targetDisplay: targetDisplayIndex ?? 0,
                sessionID: sessionID
            )
```

- [ ] **Step 4: 更新 ShutdownSnapshotManager 和 TerminalRestoreService**

文件: `Sources/Toggle/ShutdownSnapshotManager.swift:225-226`
```swift
                let moved = SpaceController.shared.moveWindow(
                    target.windowID,
                    toSpace: .yabai(spaceIndex),
                    focus: false
                )
```

文件: `Sources/Toggle/TerminalRestoreService.swift:225-229` 同理更新。

- [ ] **Step 5: 验证编译**
Run: `swift build 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 6: 提交**
Run: `git add Sources/Toggle/ Sources/Window/ && git commit -m "refactor(toggle): migrate all SpaceController consumers to strong-typed indices"`

---

### Task 3: Add documentation comments to all index-bearing API boundaries

**Depends on:** Task 2
**Files:**
- Modify: `Sources/Space/SpaceController.swift` (YabaiSpaceInfo, YabaiWindowInfo)
- Modify: `Sources/Hook/ClaudeHookModels.swift` (ToggleRecord)
- Modify: `Sources/Space/SpaceController+Context.swift` (SpaceContext)

- [ ] **Step 1: 给 YabaiSpaceInfo/YabaiWindowInfo 添加文档注释**

文件: `Sources/Space/SpaceController.swift:346-387`

```swift
/// yabai space 查询结果
/// - `id`: macOS 原生 space ID (CGS)，用于 NativeSpaceBridge.moveWindow
/// - `index`: yabai 全局 space 索引 (1-based)，用于 yabai space 命令
/// - `display`: yabai display 索引 (1-based, 1=主屏)
/// - `isVisible`: 该 space 是否是其 display 上当前可见的 space
struct YabaiSpaceInfo: Decodable {
    let id: Int?
    let index: Int?
    let display: Int?
    let isVisible: Bool?
    // ...
}

/// yabai window 查询结果
/// - `space`: 窗口所在的 yabai 全局 space 索引 (1-based)
/// - `display`: 窗口所在的 yabai display 索引 (1-based)
struct YabaiWindowInfo: Decodable {
    // ...
}
```

- [ ] **Step 2: 给 ToggleRecord 字段添加文档注释**

文件: `Sources/Hook/ClaudeHookModels.swift:122-134`

```swift
struct ToggleRecord: Equatable {
    // ...
    // MARK: - 原始位置（恢复目标）
    let origFrame: CGRect
    let sourceSpace: Int          // yabai 全局 space index (1-based)
    let sourceDisplay: Int        // ⚠️ NSScreen.screens 0-based index（历史遗留，不应在新代码中使用）
    let sourceYabaiDisp: Int      // yabai display index (1-based, 1=主屏)
    let sourceDispSpace: Int      // display-local space index (1-based, 窗口在其 display 上的第几个 space)
    // ...
}
```

- [ ] **Step 3: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 4: 提交**
Run: `git add Sources/Space/SpaceController.swift Sources/Hook/ClaudeHookModels.swift Sources/Space/SpaceController+Context.swift && git commit -m "docs(space): add index type documentation to all space/display API boundaries"`

---

### Task 4: Quality gate — full build + grep verification

**Depends on:** Task 1, Task 2, Task 3
**Files:** None (verification only)

- [ ] **Step 1: Full build verification**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 2: Verify DisplayIdentifier/SpaceIdentifier are now used**
Run: `grep -rn "DisplayIdentifier\|SpaceIdentifier" Sources/ --include="*.swift" | grep -v "CoordinateKit.swift" | wc -l`
Expected:
  - Output >= 10 (at least 10 references outside the definition file)

- [ ] **Step 3: Verify no raw Int space parameters remain in SpaceController public API**
Run: `grep -n "func.*space.*Int\|func.*display.*Int" Sources/Space/SpaceController*.swift`
Expected:
  - Public functions use SpaceIdentifier/DisplayIdentifier, not bare Int
  - Internal/private helpers may still use bare Int for yabai command construction

- [ ] **Step 4: Verify ToggleRecord has documentation on all index fields**
Run: `grep -A1 "sourceSpace\|sourceDisplay\|sourceYabaiDisp\|sourceDispSpace" Sources/Hook/ClaudeHookModels.swift | grep "//"`
Expected:
  - Each field has a comment explaining the index type
