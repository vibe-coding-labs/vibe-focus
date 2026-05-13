# Window Frame Reading Priority Standardization

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 统一窗口 frame 读取的优先级策略：yabai 优先（最准确）→ AX 兜底（需要窗口可见）。在关键读取点使用统一 helper，在安全读取点添加注释说明。

**Architecture:** 创建 `readAccurateFrame(windowID:axElement:)` 统一 helper，内部逻辑：1) 先读 AX frame（快速）2) 用 yabai frame 交叉校验 3) 如果差异 > 阈值，使用 yabai frame。在 2 个边界读取点和已有 MoveWindow.swift:126 处复用此 helper。安全读取点添加 `// AX-safe:` 注释。

**Tech Stack:** Swift 5.9, macOS AX API, yabai CLI

**Risks:**
- yabai 子进程调用增加 ~10ms 到 restore 路径 → 缓解：restore 总耗时 ~200ms，10ms 可忽略
- yabai 未安装时 helper 退化为纯 AX → 无风险，与当前行为一致

---

### Task 1: 创建 readAccurateFrame helper 并替换边界读取点

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+AXHelpers.swift:72-94`（在 `frame(of:)` 后添加新方法）
- Modify: `Sources/Window/WindowManager+Restore.swift:120`（替换为 helper）
- Modify: `Sources/Toggle/ToggleEngine.swift:138`（替换为 helper）

- [ ] **Step 1: 添加 readAccurateFrame helper — 统一 yabai 优先的 frame 读取逻辑**

文件: `Sources/Window/WindowManager+AXHelpers.swift`（在 `frame(of:)` 方法之后，`isAttributeSettable` 之前添加）

```swift
    /// 读取窗口 frame，优先使用 yabai 交叉校验确保准确性。
    /// AX API 对非可见 Space 上的窗口返回错误坐标，yabai 始终准确。
    /// 调用方应优先使用此方法而非 frame(of:)，除非确定窗口可见。
    func readAccurateFrame(windowID: UInt32, axElement: AXUIElement) -> CGRect? {
        guard let axFrame = frame(of: axElement) else {
            return nil
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

- [ ] **Step 2: 替换 Restore.swift 中的 frame 读取 — 使用 readAccurateFrame**
文件: `Sources/Window/WindowManager+Restore.swift:120`

```swift
        guard let currentFrame = readAccurateFrame(windowID: currentWindowID, axElement: window) else {
```

- [ ] **Step 3: 替换 ToggleEngine.swift 中的 frame 读取 — 使用 readAccurateFrame**
文件: `Sources/Toggle/ToggleEngine.swift:138`

```swift
        guard let currentFrame = wm.readAccurateFrame(windowID: windowID, axElement: windowAX) else {
```

- [ ] **Step 4: 重构 MoveWindow.swift 中已有的 yabai 校验 — 复用 readAccurateFrame**
文件: `Sources/Window/WindowManager+MoveWindow.swift:126-158`

将现有的内联 yabai 校验替换为 `readAccurateFrame` 调用：

```swift
        guard let origFrame = readAccurateFrame(windowID: identity.windowID, axElement: windowAX) else {
            log(
                "moveWindowToMainScreen failed: cannot read current frame",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }
```

注意：原有的 `currentFrame` 变量也需要全部替换为 `origFrame`（已在上一轮修复中完成）。此处只替换 frame 读取逻辑，保留变量名 `origFrame`。

- [ ] **Step 5: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 6: 提交**
Run: `git add Sources/Window/WindowManager+AXHelpers.swift Sources/Window/WindowManager+Restore.swift Sources/Toggle/ToggleEngine.swift Sources/Window/WindowManager+MoveWindow.swift && git commit -m "refactor(window): unify frame reading with yabai-first readAccurateFrame helper"`

---

### Task 2: 在安全读取点添加 AX-safe 注释

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Window/WindowManager+MoveWindow.swift:302`
- Modify: `Sources/Window/WindowManager+AXHelpers.swift:247`
- Modify: `Sources/Window/WindowManager+Restore.swift:217`
- Modify: `Sources/Window/WindowManager+Toggle.swift:24,173,386`

- [ ] **Step 1: 在 MoveWindow.swift:302 添加 AX-safe 注释**

```swift
        // AX-safe: reading frame after move to main screen — window is visible
        let actualTargetFrame = frame(of: windowAX) ?? targetFrame
```

- [ ] **Step 2: 在 AXHelpers.swift:247 添加 AX-safe 注释**

```swift
            // AX-safe: verifying frame after apply — window was just manipulated
            if let appliedFrame = frame(of: window) {
```

- [ ] **Step 3: 验证编译**
Run: `swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 4: 提交**
Run: `git add Sources/Window/WindowManager+MoveWindow.swift Sources/Window/WindowManager+AXHelpers.swift && git commit -m "docs(window): add AX-safe comments to visible window frame reads"`
