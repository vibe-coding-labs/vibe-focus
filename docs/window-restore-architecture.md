# 窗口恢复架构文档

## 功能是什么

用户在多显示器环境下工作。VibeFocus 的 toggle 功能把终端窗口从副屏搬到主屏（方便看），恢复功能把它搬回副屏原位。

一次完整的 toggle + restore 循环是这样的：

```
1. 窗口在副屏 Display 2, Space 3, 位置 (3200, 200)
2. 用户按 Ctrl+Q → 窗口被搬到主屏 Display 1, 位置 (0, 0)，同时把原始位置记下来
3. 用户用完了，需要把窗口搬回去
4. 恢复触发 → 读取之前记下的位置，把窗口搬回 Display 2, Space 3, (3200, 200)
```

第 3 步"恢复触发"有两种时机：
- 用户手动再按一次 Ctrl+Q
- Claude Code 发 prompt 时自动触发

## 前置：toggle 时保存了什么

恢复依赖 toggle 时保存的状态。这一步在 `moveWindowToMainScreen()`（`Sources/WindowManager+MoveWindow.swift:81`）里完成。

当窗口被搬到主屏后，代码会保存以下信息：

| 信息 | 含义 | 示例值 |
|------|------|--------|
| `windowID` | macOS 窗口编号（CGWindowNumber） | `64` |
| `pid` | 终端进程 ID | `42871` |
| `origFrame` | 窗口在副屏的原始位置和大小 | `(3200, 200, 1200, 800)` |
| `targetFrame` | 窗口被搬到主屏后的位置和大小 | `(0, 38, 1920, 1042)` |
| `sourceSpace` | 窗口原来在哪个 Space（yabai 全局索引） | `3` |
| `sourceYabaiDisp` | 窗口原来在哪个 Display（yabai 编号） | `2` |
| `sourceDispSpace` | 窗口原来在该 Display 的第几个 Space | `2` |

这些数据同时写入三个地方（都是 SQLite 的同一个 `windows` 表，但是不同字段）：
1. `SavedWindowState`（WindowManager 用）
2. `SessionWindowRegistry.toggleState`（session 绑定用）
3. `ToggleRecord`（ToggleEngine 用，前缀 `toggle_` 的字段）

然后通过 `hydrateMemory()` 把关键值加载到 WindowManager 的实例变量里：

```swift
lastWindowToken              // 窗口身份：pid, windowID, bundleIdentifier 等
lastWindowFrame              // origFrame — 窗口原始位置（恢复目标）
lastTargetFrame              // targetFrame — 窗口当前在主屏的位置（用于验证）
lastSourceSpaceIndex         // 3 — 原始 Space
lastSourceYabaiDisplayIndex  // 2 — 原始 Display
```

这些内存变量是 Ctrl+Q 手动恢复时的数据来源。

---

## 恢复触发方式 1：用户按 Ctrl+Q

**入口：** `WindowManager.toggle()`（`Sources/WindowManager.swift:140`）

### Step 1：判断该 restore 还是 move

用户每次按 Ctrl+Q，系统需要判断"这次是要搬过去还是搬回来"。判断逻辑在 `shouldRestoreCurrentWindow()`（`:783`）：

1. 拿到当前**焦点窗口**（哪个窗口在最前面）
2. 问 macOS：这个窗口在主屏还是副屏？
3. 如果在**副屏** → 用户想把它搬去主屏 → 返回 `false`（不要 restore）
4. 如果在**主屏** → 用户可能想把它搬回副屏 → 继续检查：
   - 查 `SessionWindowRegistry` 里有没有这个窗口的 toggle 状态
   - 检查 toggle 状态是否有效（origFrame 不在主屏、targetFrame 在主屏）
   - 检查窗口当前位置是否在 targetFrame 附近（确认这个窗口确实是被 toggle 过来的）
5. 全部通过 → 返回 `true`，进入 restore 流程

如果返回 `true`，`toggle()` 会调用 `shouldRestoreCurrentWindow()` 内部的 `hydrateMemory()`，把 SQLite 里的状态加载到内存变量 `lastWindowFrame`、`lastSourceSpaceIndex` 等。

### Step 2：restore() 开始执行

**方法：** `WindowManager.restore()`（`:350`）

这一步会依次做以下事情：

#### 2a. 检查有没有可用的状态

```swift
if lastWindowToken == nil || lastWindowFrame == nil || lastTargetFrame == nil {
    // 内存里没有状态 → 尝试从 SQLite 重新加载
    if shouldRestoreCurrentWindow() == false { return }
}
```

如果内存变量是空的（比如 app 刚重启过），会再走一次 `shouldRestoreCurrentWindow()` 从 SQLite 加载。

#### 2b. 找到窗口

```swift
let window = restoreWindow(using: token)
```

通过 `token` 里的 pid 和 windowID，用 macOS Accessibility API 遍历该进程的所有窗口，找到 windowID 匹配的那个 `AXUIElement`。

如果找不到（窗口已关闭、进程已退出），直接终止。

#### 2c. 检查窗口是否已经在原位

```swift
if framesMatch(currentFrame, targetFrame) {
    resetActiveWindowContext(removeState: true)
    return  // 已经在原位了，不用搬
}
```

读窗口当前 frame，和 `lastWindowFrame`（原始位置）对比。如果已经差不多在原位了（容差 150px），说明可能是上次已经恢复过了，跳过并清除状态。

#### 2d. 检查 AX 属性是否可写

```swift
isAttributeSettable(window, attribute: kAXPositionAttribute)  // 位置可写？
isAttributeSettable(window, attribute: kAXSizeAttribute)       // 大小可写？
```

有些窗口（比如系统窗口）不允许通过 AX 改位置。如果不可写，直接终止。

#### 2e. Space 预切换

**这是恢复的关键步骤。** 窗口的坐标是相对于它所在 Display 的。如果副屏当前显示的不是目标 Space，设坐标会出错。

```swift
if triggerSource == "carbon_hotkey", let targetSpace = lastSourceSpaceIndex {
    let targetDisplay = lastSourceYabaiDisplayIndex
    // 查询副屏当前显示的 Space
    let displayCurrentSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)

    if let current = displayCurrentSpace, current != targetSpace {
        // 副屏不在目标 Space → 切换
        spaceController.switchDisplayToSpace(targetSpace: targetSpace)
        usleep(400_000)  // 等 400ms 让 macOS 完成切换
    }
    // 如果副屏已经在目标 Space → 不用切，直接往下走
}
```

具体发生了什么：
- `displayVisibleSpace(displayIndex: 2)` → 问 yabai "Display 2 当前显示的是哪个 Space？" → 得到 `2`
- `targetSpace` 是 `3`（toggle 时记下来的）
- `2 != 3` → 需要切换
- `switchDisplayToSpace(targetSpace: 3)` → 先试 yabai `space --focus 3`，如果失败就用 CGEvent 发 Ctrl+Right 切换
- 等 400ms

#### 2f. 设置窗口坐标

```swift
apply(frame: lastWindowFrame, to: window)
```

用 AX API 把窗口的 position 和 size 设成 `lastWindowFrame`（toggle 时记下的原始位置）。

这时窗口已经从主屏搬到了副屏的目标 Space 上，坐标系统匹配。

#### 2g. 验证

```swift
let restoredFrame = self.frame(of: window)
framesMatch(restoredFrame, frame)  // 读回来比对
```

读回窗口实际 frame，和目标对比。如果不匹配（可能被 macOS 拒绝了），记录错误并终止。

#### 2h. 焦点跟随

```swift
if triggerSource == "carbon_hotkey" {
    // 窗口现在在副屏 Space 3，但用户焦点还在主屏
    // 把用户焦点也切过去
    spaceController.focusWindow(windowID)
}
```

#### 2i. 清理

```swift
resetActiveWindowContext(removeState: true)
```

清空内存变量（`lastWindowFrame` 等）和 SQLite 中的 `SavedWindowState` 记录。下次按 Ctrl+Q 不会再触发 restore。

---

## 恢复触发方式 2：Claude Code 发 prompt 自动恢复

**入口：** `HookEventHandler.handleUserPromptSubmit()`（`Sources/HookEventHandler.swift:97`）

这个流程更长一些，因为它需要先找到"哪个窗口需要恢复"。

### Step 1：检查开关

```swift
guard ClaudeHookPreferences.autoRestoreOnPromptSubmit else { return }
```

用户可以在设置里关掉自动恢复。如果关了，直接返回。

### Step 2：找到需要恢复的窗口

这一步要解决的问题：Claude Code 发了一个 hook 说"我收到了用户的 prompt"，但 VibeFocus 不知道这个 prompt 来自哪个终端窗口。

查找过程分两步走：

**2a. 通过 session 绑定查找**

```swift
let state = SessionWindowRegistry.shared.binding(for: payload.sessionID)
```

每个 Claude Code session 启动时，VibeFocus 会把这个 session 和它所在的终端窗口绑定（记录 pid、windowID、tty 等）。通过 hook 传来的 `sessionID` 查这个绑定。

找到后还要验证绑定是否还有效：

```swift
SessionWindowRegistry.shared.verifyBinding(state)
// 检查 pid 是否还活着、窗口是否还存在
```

**2b. 降级：通过终端上下文查找**

如果 step 2a 没有找到绑定（session 刚启动、绑定丢失等），用 hook 传来的终端上下文信息：

```swift
if let terminalCtx = payload.terminalContext, terminalCtx.hasUsefulContext {
    identity = WindowManager.shared.findWindowByTerminalContext(terminalCtx)
}
```

`terminalCtx` 包含 tty 路径（如 `/dev/ttys003`）、进程 PID 等。`findWindowByTerminalContext` 用这些信息去匹配窗口。

如果两种方式都找不到，跳过恢复。

### Step 3：确认窗口在主屏

```swift
let isOnMain = wm.isWindowOnMainScreen(windowID: identity.windowID)
guard isOnMain else { return }  // 不在主屏，不需要恢复
```

如果窗口已经在副屏了，说明可能之前已经被恢复过或者用户手动移回去了，不需要再恢复。

### Step 4：从 ToggleEngine 读取状态

```swift
if let record = engine.load(windowID: identity.windowID) {
```

用 `windowID` 直接查 SQLite 的 `windows` 表，读取 `toggle_` 前缀的字段（toggle 时写入的 ToggleRecord）。

注意这里和 Ctrl+Q 路径不同——Ctrl+Q 读的是内存变量（`lastWindowFrame` 等），这里是直接查数据库。

### Step 5：验证记录有效性

```swift
if record.isValid(mainScreenFrame: mainScreen.frame) {
```

`isValid()` 检查两件事：
- `origFrame`（原始位置）的中心点**不在**主屏上 → 说明原始位置确实在副屏
- `targetFrame`（主屏位置）的中心点**在**主屏上 → 说明 toggle 目标确实在主屏

如果两个 frame 都在主屏上，说明数据损坏了（可能两次 toggle 没有正确 restore），清除记录并终止。

### Step 6：ToggleEngine.restore() 执行

**方法：** `ToggleEngine.restore()`（`Sources/ToggleEngine.swift:84`）

#### 6a. 加载 ToggleRecord

```swift
guard let record = load(windowID: windowID) else { return false }
```

和 step 4 一样，从 SQLite 读取。

#### 6b. 找到窗口

```swift
guard let windowAX = wm.findWindowByPID(record.pid, windowID: record.windowID) else { return false }
```

遍历 pid 对应进程的所有 AX 窗口，找到 windowID 匹配的。和 Ctrl+Q 路径的 `restoreWindow()` 类似。

#### 6c. 验证窗口位置

```swift
guard let currentFrame = wm.frame(of: windowAX) else { return false }
if !record.isNearTarget(currentFrame: currentFrame) { return false }
```

读窗口当前 frame，检查是否在 `targetFrame` 附近（150px 容差）。

为什么需要这一步？防止把一个已经被用户手动移动过的窗口误恢复。只有窗口还在 toggle 目标位置附近，才认为它是"需要恢复的"。

#### 6d. Space 切换 — switchToOriginalSpace()

**方法：** `ToggleEngine.switchToOriginalSpace()`（`:154`）

这是恢复的核心，负责把副屏切到正确的 Space 并把窗口移过去。

```swift
// 要恢复到哪个 Space 和 Display？
let targetSpace = record.sourceSpace         // 例：3
let targetDisplay = record.sourceYabaiDisp   // 例：2

// 问 yabai：Display 2 当前显示的是哪个 Space？
let displayCurrentSpace = spaceController.displayVisibleSpace(displayIndex: targetDisplay)
```

然后分两种情况：

**情况 1：副屏已经在正确的 Space**

```swift
if let current = displayCurrentSpace, current == targetSpace {
    // Display 2 已经显示 Space 3，只需把窗口移过去
    spaceController.moveWindow(record.windowID, toSpaceIndex: targetSpace)
    return
}
```

**情况 2：副屏不在正确的 Space**

```swift
// 先把 Display 2 切到 Space 3
spaceController.switchDisplayToSpace(targetSpace: targetSpace)
usleep(400_000)  // 等 400ms

// 再把窗口移到 Space 3
spaceController.moveWindow(record.windowID, toSpaceIndex: targetSpace)
usleep(200_000)  // 等 200ms
```

`switchDisplayToSpace` 的内部实现：
1. 先试 `yabai -m space --focus <targetSpace>` — 如果 yabai 有权限就能直接切
2. 如果 yabai 失败 → 降级到 CGEvent：把鼠标移到目标 Display 中心 → 发 Ctrl+Left/Right 按键事件 → 鼠标移回原位

`moveWindow` 的内部实现：
- `yabai -m window <windowID> --space <targetSpace>` 把窗口分配到目标 Space

#### 6e. 重新获取 AX 元素

```swift
let restoreAX = wm.findWindowByPID(record.pid, windowID: record.windowID) ?? windowAX
```

Space 切换可能使之前的 AXUIElement 引用失效。重新查找一次，如果找不到就用旧的碰运气。

#### 6f. 设置窗口坐标

```swift
wm.apply(frame: record.origFrame, to: restoreAX)
```

和 Ctrl+Q 路径一样，用 AX API 设置窗口位置为 `origFrame`（原始位置）。

#### 6g. 清理

```swift
engine.clear(windowID: windowID)
```

清除 SQLite 中的 ToggleRecord（把 `toggle_` 前缀的字段置 NULL），防止下次误恢复。

---

## 两种触发方式的差异总结

| | Ctrl+Q 手动 | UserPromptSubmit 自动 |
|---|---|---|
| **怎么找到窗口** | 直接用当前焦点窗口 | 通过 sessionID 查绑定，或通过终端上下文匹配 |
| **状态从哪读** | WindowManager 内存变量 (`lastWindowFrame` 等) | SQLite 的 `toggle_` 字段 (`ToggleRecord`) |
| **谁来执行恢复** | `WindowManager.restore()` | `ToggleEngine.restore()` |
| **Space 切换** | 直接调 `SpaceController` | 封装在 `switchToOriginalSpace()` 里，逻辑相同 |
| **恢复后是否跟随焦点** | 是（`focusWindow` 把用户视角切到窗口所在 Space） | 否（不打断用户正在看的东西） |
| **状态清理** | `resetActiveWindowContext()` 清内存 + SQLite | `ToggleEngine.clear()` 只清 SQLite toggle 字段 |

---

## 防误恢复机制

恢复是一个危险操作——把用户的窗口突然移走。所以有层层防护：

1. **窗口必须在主屏** — 如果窗口已经不在主屏了，不恢复
2. **必须有 toggle 状态** — 没记录说明没被 toggle 过，不恢复
3. **状态必须有效** — origFrame 在副屏、targetFrame 在主屏，否则是损坏数据
4. **窗口必须在 targetFrame 附近** — 确认窗口没被用户手动移走过
5. **窗口属性必须可写** — AX position 和 size 都 settable 才能操作
6. **frame 回读验证** — apply 之后读回来确认真的设成功了
7. **Space 切换前先查** — 副屏已经在正确 Space 就不切，避免无谓操作

---

## 涉及的文件清单

| 文件 | 职责 |
|------|------|
| `Sources/WindowManager.swift` | `toggle()` 决策、`restore()` 执行、`shouldRestoreCurrentWindow()` 判断 |
| `Sources/WindowManager+MoveWindow.swift` | `moveWindowToMainScreen()` toggle 时保存状态 |
| `Sources/WindowManager+State.swift` | `hydrateMemory()` 加载状态到内存、`resetActiveWindowContext()` 清理 |
| `Sources/ToggleEngine.swift` | `restore()` + `switchToOriginalSpace()` 自动恢复路径 |
| `Sources/HookEventHandler.swift` | `handleUserPromptSubmit()` 接收 hook、找窗口、调用 ToggleEngine |
| `Sources/SessionWindowRegistry.swift` | session 和窗口的绑定关系、toggle 状态读写 |
| `Sources/SpaceController.swift` | `switchDisplayToSpace()`、`moveWindow()`、`displayVisibleSpace()` 等 Space 操作 |
| `Sources/WindowStateStore.swift` | SQLite 读写 ToggleRecord 和 SavedWindowState |
| `Sources/ClaudeHookModels.swift` | `ToggleRecord` 数据结构定义 |
