# Redundant Logic Cleanup Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 清除 toggle/restore 路径中的冗余逻辑和死代码：双重写入、双重验证、死函数、死字段、重复 SQL。保留正确行为，只删除冗余。

**Architecture:** 数据流简化：moveWindowToMainScreen 只写 ToggleEngine → WindowManager+Restore 简化为薄入口 → ToggleEngine 是唯一事实来源。清除 SessionWindowRegistry 中的 toggle 字段、死代码 readAccurateFrame、重复 SQL。

**Tech Stack:** Swift 5.9, macOS 14+, SQLite

**Risks:**
- 删除 SessionWindowRegistry toggle 写入可能影响 UI 显示 → 缓解：确认 Settings UI 读的是 ToggleEngine 还是 SessionWindowRegistry
- 合并 clear 路径可能遗漏某个调用点 → 缓解：grep 所有调用点确保覆盖

---

### Task 1: Remove Dead Code — readAccurateFrame

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+AXHelpers.swift:96-137`

- [ ] **Step 1: 删除 readAccurateFrame 函数 — 已无调用者**

文件: `Sources/Window/WindowManager+AXHelpers.swift:96-137`（删除整个 `readAccurateFrame` 函数，包括注释）

将：
```swift
    /// 读取窗口 frame，优先使用 yabai 交叉校验确保准确性。
    /// AX API 对非可见 Space 上的窗口返回错误坐标，yabai 始终准确。
    /// 调用方应优先使用此方法而非 frame(of:)，除非确定窗口可见。
    func readAccurateFrame(windowID: UInt32, axElement: AXUIElement) -> CGRect? {
        guard let axFrame = frame(of: axElement) else {
            return nil
        }
        // 主屏窗口 AX frame 准确，不需要 yabai 校验
        // yabai 使用 Cocoa 坐标（Y-up），AX 使用 Quartz 坐标（Y-down）
        // 对主屏窗口做 yabai override 会因坐标系不同导致错误
        if isWindowOnMainScreen(windowID: windowID) {
            return axFrame
        }
        guard let yabaiInfo = spaceController.queryWindow(windowID: windowID),
              let yabaiFrame = yabaiInfo.frame else {
            return axFrame
        }
        // yabai 返回 Quartz 坐标（Y-down, origin at top-left of primary）
        // 与 AX/apply 坐标系一致，不需要转换
        let yabaiRect = yabaiFrame.cgRect
        let positionDiff = hypot(yabaiRect.midX - axFrame.midX, yabaiRect.midY - axFrame.midY)
        let sizeDiff = max(abs(yabaiRect.width - axFrame.width), abs(yabaiRect.height - axFrame.height))

        // 位置 OR 尺寸任一偏差过大，都应使用 yabai 的数据
        // AX 对非可见 Space 窗口可能返回正确的位置但错误的尺寸（如残留主屏尺寸）
        if positionDiff > frameTolerance * 3 || sizeDiff > frameTolerance * 3 {
            log(
                "[WindowManager] readAccurateFrame: yabai override",
                level: .info,
                fields: [
                    "windowID": String(windowID),
                    "axFrame": "\(axFrame)",
                    "yabaiFrame": "\(yabaiRect)",
                    "positionDiff": String(format: "%.0f", positionDiff),
                    "sizeDiff": String(format: "%.0f", sizeDiff),
                    "reason": sizeDiff > frameTolerance * 3 ? "size_mismatch" : "position_mismatch"
                ]
            )
            return yabaiRect
        }
        return axFrame
    }
```

替换为：（无代码 — 直接删除）

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Window/WindowManager+AXHelpers.swift && git commit -m "refactor: remove dead readAccurateFrame function — no callers after recent fix"`

---

### Task 2: Remove Redundant Toggle Write from SessionWindowRegistry

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Window/WindowManager+MoveWindow.swift:297-324`
- Modify: `Sources/Hook/SessionWindowRegistry.swift` — search for `clearToggleState` and remove
- Modify: `Sources/Window/WindowManager+Restore.swift` — remove `SessionWindowRegistry.shared.clearToggleState` call

- [ ] **Step 1: 移除 moveWindowToMainScreen 中的 SessionWindowRegistry toggle 写入**

文件: `Sources/Window/WindowManager+MoveWindow.swift:297-324`（删除 SessionWindowRegistry.updateToggleState 调用块）

将：
```swift
        // 写入 1: SessionWindowRegistry（session 绑定 + toggle state，写 SQLite）
        SessionWindowRegistry.shared.updateToggleState(
            windowID: effectiveWindowID
        ) { state in
            state.pid = identity.pid
            state.appName = identity.appName
            state.bundleIdentifier = identity.bundleIdentifier
            state.title = resolvedTitle
            state.axWindowNumber = resolvedWindowNumber
            state.origX = origFrame.origin.x
            state.origY = origFrame.origin.y
            state.origW = origFrame.width
            state.origH = origFrame.height
            state.targetX = actualTargetFrame.origin.x
            state.targetY = actualTargetFrame.origin.y
            state.targetW = actualTargetFrame.width
            state.targetH = actualTargetFrame.height
            state.sourceSpace = spaceContext.sourceSpaceIndex
            state.sourceDisplay = sourceContext.index
            state.sourceYabaiDisp = spaceContext.sourceDisplayIndex
            state.sourceDispSpace = spaceContext.sourceDisplaySpaceIndex
            state.targetDisplay = targetDisplayIndex
            state.toggleReason = reason.rawValue
            state.toggledAt = Date()
            if let sid = sessionID {
                state.sessionID = sid
            }
        }

        // 写入 2: ToggleEngine（SQLite 单一事实来源，restore 时直接读这里）
```

替换为：
```swift
        // 写入: ToggleEngine（SQLite 单一事实来源，restore 时直接读这里）
```

- [ ] **Step 2: 移除 WindowManager+Restore 中的冗余 clear 调用**

文件: `Sources/Window/WindowManager+Restore.swift`（搜索 `clearToggleState` 的调用行）

搜索 `SessionWindowRegistry.shared.clearToggleState` 并删除该行。保留 `engine.clear(windowID:)` 调用。

- [ ] **Step 3: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 构建部署**
Run: `bash scripts/dev-build.sh 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "构建成功"

- [ ] **Step 5: 重启 VibeFocus 并验证无报错**
Run: `pkill -x VibeFocus; sleep 1; open /Applications/VibeFocus.app; sleep 3; tail -10 /Users/cc11001100/Library/Logs/VibeFocus/vibefocus.log | grep -i "error\|crash\|fatal" || echo "No errors"`
Expected:
  - Output: "No errors"

- [ ] **Step 6: 提交**
Run: `git add Sources/Window/WindowManager+MoveWindow.swift Sources/Window/WindowManager+Restore.swift && git commit -m "refactor: remove redundant SessionWindowRegistry toggle write — ToggleEngine is single source of truth"`

---

### Task 3: Simplify WindowManager+Restore — Remove Redundant Pre-Validation

**Depends on:** Task 2
**Files:**
- Modify: `Sources/Window/WindowManager+Restore.swift` — simplify restore() to thin delegation

- [ ] **Step 1: 简化 restore() 为薄委托入口**

读取 `Sources/Window/WindowManager+Restore.swift` 完整内容，然后将 `restore()` 方法简化为：
1. 检查 accessibility 权限
2. 获取当前焦点窗口
3. 调用 `ToggleEngine.shared.restore(windowID:triggerSource:traceID:)`
4. 返回结果

删除所有重复的验证逻辑（load record、find AX element、isNearTarget check、framesMatch check、AX settable check）— 这些已在 ToggleEngine.restore() 中执行。

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 构建部署并验证**
Run: `bash scripts/dev-build.sh 2>&1 | tail -10 && pkill -x VibeFocus; sleep 1; open /Applications/VibeFocus.app; sleep 3; tail -10 /Users/cc11001100/Library/Logs/VibeFocus/vibefocus.log | grep -i "error\|crash\|fatal" || echo "No errors"`
Expected:
  - Output contains: "构建成功"
  - Output contains: "No errors"

- [ ] **Step 4: 提交**
Run: `git add Sources/Window/WindowManager+Restore.swift && git commit -m "refactor: simplify WindowManager+Restore to thin delegation — ToggleEngine handles all validation"`
