# Space Index Bug Postmortem — 反复出现的工作区索引错误

## 问题

Toggle restore 后窗口回到错误的工作区（Space），表现为"索引反着来"或"在 Space 2 和 3 之间弹跳"。用户按 Ctrl+Q 把窗口切到主屏，再按 Ctrl+Q 切回来，窗口不在原来的 Space 上。

## 根因（2026-05-12 修复）

`preferredSourceSpace()` 在 `windowSpace != visibleSpace` 时错误地返回 `visibleSpace`。

文件：`Sources/Space/SpaceController+Context.swift:174-180`

```swift
// 修复前（错误）:
if let windowSpace, let visibleSpace, windowSpace != visibleSpace {
    return visibleSpace  // ← 存了可见空间，不是窗口实际空间
}

// 修复后（正确）:
if let windowSpace, let visibleSpace, windowSpace != visibleSpace {
    return windowSpace   // ← 存窗口实际空间
}
```

**因果链：**
1. Toggle 时窗口在 Space 3（windowSpace=3），但副屏显示 Space 2（visibleSpace=2）
2. `preferredSourceSpace` 返回 visibleSpace=2 → toggle record 存 sourceSpace=2
3. Restore 时：切换副屏到 Space 2 → 应用 frame → macOS 把窗口放回 Space 3（它记住的实际空间）
4. "following window" 跟随窗口到 Space 3 → 用户看到 Space 3 而非 Space 2

## 这是同一个 bug 的第 N 次出现

| 日期 | 文档 | 表现 | 根因归类 |
|------|------|------|---------|
| 04-11 | auto-switch-space-before-restore | restore 后窗口在错误 Space | 先 moveWindow 后 focusSpace，顺序错 |
| 04-13 | fix-moveWindowToMainScreen-nonvisible-workspace | AX frame 对非可见 Space 窗口报错坐标 | AX 坐标不可靠 |
| 04-13 | fix-focusSpace-cgEvent-fallback | CGEvent 只切焦点 Display | CGEvent 不切目标 Display |
| 05-05 | fix-toggle-restore-wrong-space | focusSpace 切错 Display | 同上，CGEvent 只影响焦点 Display |
| 05-05 | fix-toggle-engine-space-restore | sourceDisplay 始终为 0 | AX displayContext 对非活跃窗口返回 nil |
| 05-05 | toggle-engine-rewrite | 空间切换 100% 失败 | NativeSpaceBridge 无 fallback |
| 05-10 | toggle-corruption-fix-and-logging | windowID 不一致覆盖 toggle record | windowID resolve 匹配错误窗口 |
| 05-11 | fix-toggle-stuck-on-main-screen | 窗口在主屏无 toggle record 无法切回 | 缺少 stuck 状态处理 |
| **05-12** | **本次修复** | **工作区索引反着来** | **preferredSourceSpace 用了 visibleSpace** |

## 核心不变量（以后改这段代码必须遵守）

### 1. Toggle record 必须存 windowSpace，不是 visibleSpace

```
sourceSpace = 窗口实际所在的 Space（yabai window.space）
            ≠ 当前可见的 Space（displayVisibleSpace）
```

macOS 会记住窗口属于哪个 Space。Restore 时窗口会回到它记住的 Space，不是 toggle 时用户看到的 Space。如果存了 visibleSpace，restore 的 Space 预切换就会切错。

### 2. AX frame 坐标对非可见 Space 的窗口不可靠

窗口不在当前可见 Space 上时，AX API 报告的坐标可能错误（重叠在主屏区域）。判断窗口在哪个屏幕，必须用 yabai `window.display` 或 CGWindowListCopyWindowInfo，不能只看 AX frame。

### 3. CGEvent Ctrl+Left/Right 只影响鼠标所在的 Display

`NativeSpaceBridge.focusSpace(steps:)` 发送的 Ctrl+Left/Right 只切换鼠标指针所在 Display 的 Space。调用前必须先把鼠标移到目标 Display（代码里已经这么做了，但历史上多次因为顺序错误导致切错 Display）。

### 4. space 切换后不要立刻 apply frame

Space 切换有动画延迟。yabai 可能已经报告切换完成，但 macOS WindowServer 还在过渡中。此时 apply frame 会导致窗口被分配到错误的 Space。当前代码用 400ms 轮询等待，但极端情况下可能不够。

### 5. "Following window" 要验证目标 Space

Restore 后如果窗口实际 Space 与预期不符（postApplySpace != targetSpace），应该记录警告而不是默默跟随。盲目跟随会导致用户视角弹到错误 Space。

## 代码检查清单

改动以下文件时必须对照此清单：

**`Sources/Space/SpaceController+Context.swift`** — `preferredSourceSpace()`
- [ ] 返回值是 windowSpace（窗口实际空间），不是 visibleSpace
- [ ] 不存在任何"prefer visible"逻辑

**`Sources/Window/WindowManager+Restore.swift`** — restore 空间切换 + following window
- [ ] Space 预切换用的是 toggle record 中的 sourceSpace（= windowSpace）
- [ ] following window 前检查 postApplySpace == targetSpace，不一致时 log warn
- [ ] 不存在 sourceSpace = visibleSpace 的路径

**`Sources/Window/WindowManager+MoveWindow.swift`** — toggle record 保存
- [ ] `captureSpaceContext` 的 sourceSpaceIndex 是 windowSpace
- [ ] 不依赖 AX displayContext（可能为 nil）判断 sourceDisplay

**`Sources/Space/SpaceController+Switch.swift`** — CGEvent space 切换
- [ ] Ctrl+Left/Right 前鼠标已移到目标 Display
- [ ] 有 yabai fallback（CGEvent 不是唯一策略）

## 如何验证修复

1. iTerm 窗口在副屏 Space 3 上，副屏当前显示 Space 2
2. 按 Ctrl+Q → 窗口移到主屏
3. 按 Ctrl+Q → 窗口应回到副屏 Space 3（不是 Space 2）
4. 再按 Ctrl+Q → 窗口回到主屏
5. 循环测试 5 次无弹跳

日志验证：搜索 `spaceMatchTarget`，应为 `true`。如果为 `false` 说明还有问题。
