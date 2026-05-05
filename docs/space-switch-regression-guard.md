# 工作区切换（Space Switch）回归防护

## 核心功能

VibeFocus 的核心能力：当用户从主屏幕恢复窗口到副屏幕时，不仅窗口位置要回到副屏坐标，
**用户的活跃工作区（Space）也必须自动切换到副屏的 Space**，让窗口立刻可见。

## 工作区切换的完整流程

```
restore() 调用
  → applySpaceStrategyForRestore()
    → switchToOriginal 策略
      → Phase 1: focusSpace(sourceSpace)  — 切换用户活跃 Space 到目标
      → Phase 2: moveWindow(windowID, sourceSpace)  — 正式移动窗口到目标 Space
        → NativeSpaceBridge.moveWindow (CGS API, 不需要 SA)
        → yabai -m window --space (需要 SA，但 move 命令偶尔不需要)
      → focusWindow(windowID)  — 聚焦窗口
  → AX frame 设置  — 设置窗口坐标/大小
```

**三个步骤缺一不可**：
1. **focusSpace**：切换用户当前看到的 Space（否则窗口在后台 Space）
2. **moveWindow**：正式将窗口注册到目标 Space（否则窗口在原 Space 的坐标偏移）
3. **AX frame**：设置窗口坐标和大小

## 历史回归 Bug 清单

### Bug #1: focusSpaceKnownBroken 导致整个 Space 策略被跳过（2026-05-04）

**现象**：窗口恢复到副屏坐标，但用户活跃 Space 没切换，窗口在后台不可见

**根因**：为了优化性能，添加了 `focusSpaceKnownBroken` 标记。当 yabai SA 不可用时
focusSpace 会失败，然后标记 `focusSpaceKnownBroken = true`。但后续代码用这个标记
跳过了**整个** `applySpaceStrategyForRestore`，包括 moveWindow 和 focusWindow。

**错误代码**（已删除）：
```swift
// ❌ 错误：跳过整个 Space 策略
if focusSpaceKnownBroken {
    return true  // 这导致 moveWindow 和 focusWindow 都不执行
}
```

**正确做法**：只跳过 yabai focusSpace（已知失败），保留 NativeSpaceBridge.moveWindow
和 focusWindow。NativeSpaceBridge 使用 CGS 私有 API，不需要 SA。

### Bug #2: SQLite 迁移后 savedWindowStates 数组不再更新（2026-05-04）

**现象**：toggle 热键恢复窗口时找不到已保存的状态

**根因**：SQLite 迁移后 `saveWindowState()` 只写 SQLite，不再更新内存数组
`savedWindowStates`。但 `shouldRestoreCurrentWindow()` 仍 fallback 到这个空数组。

**修复**：所有状态查询都走 SQLite，移除对 `savedWindowStates` 数组的依赖。

### Bug #3: toggle 热键优先使用 lastWindowToken 而非焦点窗口（2026-05-04）

**现象**：toggle 热键操作错误的窗口

**根因**：`shouldRestoreCurrentWindow()` 优先匹配 `lastWindowToken`（上一次操作的窗口），
而非当前实际焦点窗口。如果用户在两次 toggle 之间切换了焦点窗口，会操作错误窗口。

**修复**：重写 `shouldRestoreCurrentWindow()` 以当前焦点窗口的屏幕位置为判断依据。

## 防护规则

### 规则 1: 任何性能优化都不能跳过 Space 切换

```
性能优化可以：
- 跳过已知失败的 yabai focusSpace
- 减少 usleep 等待时间
- 缓存 yabai 查询结果

性能优化绝不能：
- 跳过 NativeSpaceBridge.moveWindow
- 跳过 focusWindow
- 在 focusSpaceKnownBroken 时跳过整个 applySpaceStrategyForRestore
- 只做 AX frame 设置而不做 Space 移动
```

### 规则 2: AX frame 设置不是 Space 移动的替代方案

AX frame 设置把窗口移到副屏坐标时，macOS 会自动将窗口移到对应 Space，
但**不会切换用户活跃 Space**。用户仍停留在原 Space，窗口在后台。

### 规则 3: 修改 Space 相关代码后必须验证

任何修改 `applySpaceStrategyForRestore`、`moveWindow`、`focusSpace` 的代码后，
必须手动测试：
1. 从副屏 toggle 到主屏（窗口移到主屏 Space 1）
2. 从主屏 toggle 回副屏（窗口移到副屏 Space N，**用户活跃 Space 切换到 N**）
3. Hook 自动恢复（同样验证 Space 切换）

### 规则 4: yabai SA 不可用时的降级路径

```
yabai SA 可用时：
  focusSpace → yabai -m space --focus N（需要 SA）
  moveWindow → yabai -m window --space N（move 不一定需要 SA）

yabai SA 不可用时：
  focusSpace → 跳过（yabai 失败，CGEvent fallback 效果差）
  moveWindow → NativeSpaceBridge.moveWindow（CGS API，不需要 SA）✓
  focusWindow → yabai -m window --focus ID（不需要 SA）✓
```

**关键**：NativeSpaceBridge.moveWindow 和 yabai focusWindow 都不需要 SA，
即使 SA 不可用也必须执行。
