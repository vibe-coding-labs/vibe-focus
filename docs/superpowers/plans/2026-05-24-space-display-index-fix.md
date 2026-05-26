# Refactor: Space/Display Index Type Safety

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 激活 CoordinateKit 中已定义的 DisplayIdentifier/SpaceIdentifier 枚举，将 SpaceController 公共 API 从裸 `Int` 升级为强类型，消除索引混淆的根因。

**Architecture:** 分三层改造：① 先扩展枚举加便捷方法 ② SpaceController API 层改用强类型（内部保持裸 Int 与 yabai 交互） ③ 消费者适配。行为不变，只改类型签名。

**Before:** 所有 space/display 参数用裸 `Int`，无法区分 yabai global index vs NSScreen array index
**After:** SpaceController 公共方法使用 `SpaceIdentifier`/`DisplayIdentifier`，编译器强制区分

**Scope:** Medium (8 files)
**Risk:** Medium (API 签名变更影响多个消费者)

**Risks:**
- Task 2 修改 SpaceContext 字段类型 — 立即 break 所有读取 sourceSpaceIndex 等字段的代码 → 缓解：Task 2-3 在同一轮完成
- Task 4 修改 SpaceController+Move 函数签名 — moveWindow 是 restore 路径核心 → 缓解：先改 API 再 grep 更新所有调用点
- ShutdownSnapshotManager 中 TerminalRestoreService.moveWindow 调用也需适配 → 缓解：Task 5 覆盖

**Autonomy Level:** Full

---

### Task 1: 扩展 DisplayIdentifier/SpaceIdentifier 添加便捷工厂方法

**Depends on:** None
**Files:**
- Modify: `Sources/Space/CoordinateKit.swift:26-41` (在 SpaceIdentifier 定义之后插入扩展)

- [ ] **Step 1: 在 DisplayIdentifier 和 SpaceIdentifier 后面添加便捷扩展**

文件: `Sources/Space/CoordinateKit.swift`（在 `SpaceIdentifier` 的 `}` 之后、`QuartzRect` 之前插入）

```swift
// MARK: - DisplayIdentifier Convenience

extension DisplayIdentifier {
    var yabaiIndex: Int? { if case .yabaiIndex(let i) = self { return i } else { return nil } }
    static func yabai(_ index: Int) -> DisplayIdentifier { .yabaiIndex(index) }
    static func screenArray(_ index: Int) -> DisplayIdentifier { .screenArrayIndex(index) }
    static func cgDisplay(_ id: UInt32) -> DisplayIdentifier { .cgDirectDisplayID(id) }
}

// MARK: - SpaceIdentifier Convenience

extension SpaceIdentifier {
    var yabaiIndex: Int? { if case .yabaiIndex(let i) = self { return i } else { return nil } }
    static func yabai(_ index: Int) -> SpaceIdentifier { .yabaiIndex(index) }
    static func native(_ id: Int64) -> SpaceIdentifier { .nativeID(id) }
}
```

- [ ] **Step 2: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 3: 提交**
Run: `git add Sources/Space/CoordinateKit.swift && git commit -m "refactor(space): add convenience extensions to DisplayIdentifier/SpaceIdentifier"`

---

### Task 2: 将 SpaceContext 字段升级为强类型

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Space/SpaceController.swift:46-51` (SpaceContext struct)
- Modify: `Sources/Space/SpaceController+Context.swift:7-54` (captureSpaceContext)

- [ ] **Step 1: 修改 SpaceContext 结构体使用强类型**

文件: `Sources/Space/SpaceController.swift:46-51`（替换整个 SpaceContext struct）

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

- [ ] **Step 2: 修改 captureSpaceContext 返回强类型**

文件: `Sources/Space/SpaceController+Context.swift:48-53`（替换 return 语句）

将：
```swift
        return SpaceContext(
            sourceSpaceIndex: sourceSpace,
            targetSpaceIndex: visibleSpaceOnDisplay,
            sourceDisplayIndex: windowDisplay,
            sourceDisplaySpaceIndex: localSpace
        )
```

替换为：
```swift
        return SpaceContext(
            sourceSpaceIndex: sourceSpace.map { .yabai($0) },
            targetSpaceIndex: visibleSpaceOnDisplay.map { .yabai($0) },
            sourceDisplayIndex: windowDisplay.map { .yabai($0) },
            sourceDisplaySpaceIndex: localSpace
        )
```

- [ ] **Step 3: 验证编译 — 预期消费者报错**
Run: `swift build 2>&1 | grep "error:" | head -10`
Expected:
  - 消费者文件报类型不匹配错误（将在 Task 3-5 修复）
  - SpaceController+Context.swift 本身无错误

---

### Task 3: 修改 SpaceController+Query 返回强类型

**Depends on:** Task 2
**Files:**
- Modify: `Sources/Space/SpaceController+Query.swift:79-109` (三个 query 函数)

- [ ] **Step 1: 修改 visibleSpaceIndex、windowSpaceIndex、windowDisplayIndex 返回强类型**

文件: `Sources/Space/SpaceController+Query.swift:79-109`（替换这三个函数）

```swift
    func visibleSpaceIndex(forDisplayIndex displayIndex: Int?, spaces: [YabaiSpaceInfo]? = nil) -> SpaceIdentifier? {
        guard let displayIndex else {
            return nil
        }
        let resolvedSpaces = spaces ?? querySpaces()
        return resolvedSpaces?.first(where: { $0.display == displayIndex && $0.isVisible == true })?.index.map { .yabai($0) }
    }

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

同时修改 `SpaceController+Move.swift:317-319` 的 `displayVisibleSpace`：
```swift
    func displayVisibleSpace(displayIndex: DisplayIdentifier?) -> SpaceIdentifier? {
        guard let idx = displayIndex?.yabaiIndex else { return nil }
        return visibleSpaceIndex(forDisplayIndex: idx)
    }
```

- [ ] **Step 2: 验证编译 — 更多消费者报错**
Run: `swift build 2>&1 | grep "error:" | wc -l`
Expected:
  - 错误数量增加（消费者文件）
  - SpaceController+Query/Move 本身无错误

---

### Task 4: 修改 SpaceController+Switch/+Move 公共 API 接受强类型

**Depends on:** Task 3
**Files:**
- Modify: `Sources/Space/SpaceController+Switch.swift:7-8` (switchDisplayToSpace 签名)
- Modify: `Sources/Space/SpaceController+Switch.swift:91` (focusSpace 签名)
- Modify: `Sources/Space/SpaceController+Move.swift:7` (moveWindow 签名)

- [ ] **Step 1: 修改 switchDisplayToSpace 签名**

文件: `Sources/Space/SpaceController+Switch.swift`

将函数签名从：
```swift
    func switchDisplayToSpace(targetSpace: Int, operationID: String?) -> Bool {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
```

改为：
```swift
    func switchDisplayToSpace(targetSpace: SpaceIdentifier, operationID: String?) -> Bool {
        let op = operationID ?? "none"
        guard let targetSpaceIndex = targetSpace.yabaiIndex else {
            log("[SpaceController] switchDisplayToSpace: unsupported space identifier", level: .warn, fields: ["op": op])
            return false
        }
        refreshAvailabilityIfNeeded()
```

函数体中所有对 `targetSpace` 的引用改为 `targetSpaceIndex`（这是裸 Int，传给 yabai 命令）。具体修改：
- `"targetSpace": String(targetSpace)` → `"targetSpace": String(targetSpaceIndex)`
- `String(targetSpace)` → `String(targetSpaceIndex)` （在 log fields 中）
- yabai arguments 中的 `String(targetSpace)` → `String(targetSpaceIndex)`
- `calculateFocusSteps(targetSpaceIndex: targetSpace)` → `calculateFocusSteps(targetSpaceIndex: targetSpaceIndex)`
- `saveAndMoveCursor(toSpace: targetSpace, ...)` → `saveAndMoveCursor(toSpace: targetSpaceIndex, ...)`
- `querySpaces()?.first(where: { $0.index == targetSpace })` → `querySpaces()?.first(where: { $0.index == targetSpaceIndex })`
- `postSwitchSpace == targetSpace` → `postSwitchSpace == targetSpaceIndex`

- [ ] **Step 2: 修改 focusSpace 签名**

文件: `Sources/Space/SpaceController+Switch.swift:91`

将：
```swift
    func focusSpace(_ spaceIndex: Int, operationID: String? = nil) -> Bool {
```
改为：
```swift
    func focusSpace(_ space: SpaceIdentifier, operationID: String? = nil) -> Bool {
        guard let spaceIndex = space.yabaiIndex else {
            log("[SpaceController] focusSpace: unsupported space identifier", level: .warn, fields: ["op": operationID ?? "none"])
            return false
        }
```

函数体中其余 `spaceIndex` 引用保持不变（已是裸 Int 变量名）。

- [ ] **Step 3: 修改 moveWindow 签名**

文件: `Sources/Space/SpaceController+Move.swift:7`

将：
```swift
    func moveWindow(_ windowID: UInt32, toSpaceIndex spaceIndex: Int, focus: Bool, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
```
改为：
```swift
    func moveWindow(_ windowID: UInt32, toSpace space: SpaceIdentifier, focus: Bool, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        guard let spaceIndex = space.yabaiIndex else {
            log("[SpaceController] moveWindow: unsupported space identifier", level: .warn, fields: ["op": op])
            return false
        }
```

函数体中 `spaceIndex` 已是局部变量，不需要改动。但需要注意 `nativeSpaceID(forYabaiIndex: spaceIndex)` 保持调用。

- [ ] **Step 4: 验证编译 — SpaceController 内部干净**
Run: `swift build 2>&1 | grep "SpaceController" | grep "error:"`
Expected:
  - SpaceController 文件本身无编译错误
  - 所有错误来自消费者文件

---

### Task 5: 更新所有消费者使用强类型

**Depends on:** Task 4
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift` (save 方法签名)
- Modify: `Sources/Toggle/ToggleEngine+Restore.swift` (restore 路径所有 SpaceController 调用)
- Modify: `Sources/Window/WindowManager+MoveWindow.swift` (save 调用 + spaceContext 读取)
- Modify: `Sources/Toggle/ShutdownSnapshotManager.swift` (spaceIndex 读取)
- Modify: `Sources/Toggle/TerminalRestoreService.swift` (moveWindow 调用)

- [ ] **Step 1: 更新 ToggleEngine.save 签名和 ToggleRecord 构造**

文件: `Sources/Toggle/ToggleEngine.swift:27-39`

save 方法参数改为强类型，ToggleRecord 构造时提取裸值：

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

ToggleRecord 构造部分（约 line 61-75）提取裸值：
```swift
        let record = ToggleRecord(
            windowID: windowID,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            origFrame: origFrame,
            sourceSpace: sourceSpace.yabaiIndex ?? 0,
            sourceDisplay: sourceDisplay.yabaiIndex ?? 0,
            sourceYabaiDisp: sourceYabaiDisp.yabaiIndex ?? 0,
            sourceDispSpace: sourceDispSpace,
            targetFrame: targetFrame,
            targetDisplay: targetDisplay,
            toggledAt: Date(),
            sessionID: sessionID
        )
```

log 部分同步更新：`String(sourceSpace.yabaiIndex ?? 0)` 等。

- [ ] **Step 2: 更新 ToggleEngine+Restore 中的所有 SpaceController 调用**

文件: `Sources/Toggle/ToggleEngine+Restore.swift`

模式：所有 `spaceController.xxx(someInt, ...)` 改为 `spaceController.xxx(.yabai(someInt), ...)`

具体修改点（grep 定位）：
1. `spaceController.switchDisplayToSpace(targetSpace: record.sourceSpace, ...)` → `spaceController.switchDisplayToSpace(targetSpace: .yabai(record.sourceSpace), ...)`
2. `spaceController.moveWindow(postMoveWindowID, toSpaceIndex: record.sourceSpace, ...)` → `spaceController.moveWindow(postMoveWindowID, toSpace: .yabai(record.sourceSpace), ...)`
3. `spaceController.windowSpaceIndex(windowID: postMoveWindowID) == record.sourceSpace` → `spaceController.windowSpaceIndex(windowID: postMoveWindowID)?.yabaiIndex == record.sourceSpace`
4. `spaceController.displayVisibleSpace(displayIndex: targetDisplay)` → `spaceController.displayVisibleSpace(displayIndex: .yabai(targetDisplay))`
5. `spaceController.displayVisibleSpace(displayIndex: disp)` → `spaceController.displayVisibleSpace(displayIndex: .yabai(disp))`
6. `spaceController.switchDisplayToSpace(targetSpace: actualSpace, ...)` → `spaceController.switchDisplayToSpace(targetSpace: .yabai(actualSpace), ...)`
7. `spaceController.switchDisplayToSpace(targetSpace: final, ...)` → `spaceController.switchDisplayToSpace(targetSpace: .yabai(final), ...)`
8. `spaceController.switchDisplayToSpace(targetSpace: preVis, ...)` → `spaceController.switchDisplayToSpace(targetSpace: .yabai(preVis), ...)`
9. `spaceController.switchDisplayToSpace(targetSpace: vis, ...)` → `spaceController.switchDisplayToSpace(targetSpace: .yabai(vis), ...)`

对于 `preRestoreDisplaySpaces` 和 `intentionallySwitchedDisplays` 的比较，`displayVisibleSpace` 返回 `SpaceIdentifier?`，需要 `.yabaiIndex` 提取后与 `Int` 比较。

- [ ] **Step 3: 更新 WindowManager+MoveWindow 中的 save 调用和 spaceContext 读取**

文件: `Sources/Window/WindowManager+MoveWindow.swift:281-310`

将 `spaceContext.sourceSpaceIndex` 从 `Int?` 改为 `SpaceIdentifier?`，读取时用 `.yabaiIndex`：
```swift
        if let sourceSpaceIndex = spaceContext.sourceSpaceIndex?.yabaiIndex {
            let teSourceDisplay = spaceContext.sourceDisplayIndex ?? .screenArray(sourceContext.index ?? 0)
```

save 调用改为传强类型：
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

文件: `Sources/Toggle/TerminalRestoreService.swift:225-229` 同理：
```swift
                    let moved = SpaceController.shared.moveWindow(
                        target.windowID,
                        toSpace: .yabai(spaceIndex),
                        focus: false
                    )
```

- [ ] **Step 5: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 6: 提交**
Run: `git add Sources/ && git commit -m "refactor(space): migrate SpaceController API to DisplayIdentifier/SpaceIdentifier strong types"`

---

### Task 6: 添加文档注释到所有索引字段

**Depends on:** Task 5
**Files:**
- Modify: `Sources/Space/SpaceController.swift` (YabaiSpaceInfo, YabaiWindowInfo structs)
- Modify: `Sources/Hook/ClaudeHookModels.swift` (ToggleRecord fields)

- [ ] **Step 1: 给 YabaiSpaceInfo 和 YabaiWindowInfo 添加文档注释**

文件: `Sources/Space/SpaceController.swift`（在 struct 定义前添加注释）

```swift
/// yabai space 查询结果
/// - `id`: macOS native space ID (CGS)，用于 NativeSpaceBridge.moveWindow
/// - `index`: yabai 全局 space 索引 (1-based)，用于 yabai space 命令
/// - `display`: yabai display 索引 (1-based, 1=主屏)
struct YabaiSpaceInfo: Decodable {
```

```swift
/// yabai window 查询结果
/// - `space`: 窗口所在的 yabai 全局 space 索引 (1-based)
/// - `display`: 窗口所在的 yabai display 索引 (1-based)
struct YabaiWindowInfo: Decodable {
```

- [ ] **Step 2: 给 ToggleRecord 字段添加注释**

文件: `Sources/Hook/ClaudeHookModels.swift:129-134`

```swift
    // MARK: - 原始位置（恢复目标）
    let origFrame: CGRect
    let sourceSpace: Int          // yabai 全局 space index (1-based)
    let sourceDisplay: Int        // ⚠️ 历史遗留：可能为 NSScreen 0-based 或 yabai 1-based
    let sourceYabaiDisp: Int      // yabai display index (1-based, 1=主屏)
    let sourceDispSpace: Int      // display-local space index (1-based)
```

- [ ] **Step 3: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 4: 提交**
Run: `git add Sources/Space/SpaceController.swift Sources/Hook/ClaudeHookModels.swift && git commit -m "docs(space): document index types on all space/display API boundaries"`

---

### Task 7: Quality gate — full build + grep verification

**Depends on:** Task 6
**Files:** None (verification only)

- [ ] **Step 1: Full build verification**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 2: Verify DisplayIdentifier/SpaceIdentifier are now actively used**
Run: `grep -rn "DisplayIdentifier\|SpaceIdentifier" Sources/ --include="*.swift" | grep -v "CoordinateKit.swift" | wc -l`
Expected:
  - Output >= 10

- [ ] **Step 3: Verify SpaceContext uses strong types**
Run: `grep -A3 "struct SpaceContext" Sources/Space/SpaceController.swift`
Expected:
  - Output contains "SpaceIdentifier" and "DisplayIdentifier"

- [ ] **Step 4: Verify moveWindow signature uses strong type**
Run: `grep "func moveWindow" Sources/Space/SpaceController+Move.swift`
Expected:
  - Output contains "toSpace space: SpaceIdentifier"
