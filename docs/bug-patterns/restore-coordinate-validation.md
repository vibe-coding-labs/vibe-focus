# Bug 模式：Restore 坐标验证阻止合法窗口恢复

## Bug 表现
Ctrl+Q 能把窗口从副屏移到主屏，但再按 Ctrl+Q 移回去时完全没反应。
日志显示类似 "origFrame off-screen" 或坐标被判定为不在任何屏幕上。

## 发生频率
**极高** — 这个 bug 在历史代码中出现过几十次。每次"修复"后，改动代码时又会有人
（包括 AI）顺手加一个"安全验证"然后又触发。

## 根因分析

### 核心问题：macOS 坐标系 + 多显示器排列

macOS 使用两套坐标系：
- **Quartz（CoreGraphics）**: 原点在主屏左上角，Y 轴向下。AX API、CGWindowList、yabai 使用。
- **Cocoa（AppKit）**: 原点在主屏左下角，Y 轴向上。NSScreen 使用。

副屏可以放在主屏的**任意位置**（上、下、左、右），导致：

| 副屏位置 | Quartz Y 值 | 含义 |
|---------|-------------|------|
| 主屏上方 | **负数** (如 -707) | 完全合法的坐标 |
| 主屏下方 | > 主屏高度 (如 1500) | 完全合法的坐标 |
| 主屏左边 | **负数 X** (如 -1920) | 完全合法的坐标 |
| 主屏右边 | > 主屏宽度 (如 2500) | 完全合法的坐标 |

### 典型错误模式

```swift
// ❌ BUG: 用 NSScreen.screens 检查坐标是否"在屏幕上"
let screens = NSScreen.screens
let onAnyScreen = screens.contains { $0.frame.contains(center) }
if !onAnyScreen { return }  // 这里会误杀合法坐标

// ❌ BUG: 检查 Y 值是否为负数
if origFrame.origin.y < 0 { return }  // 副屏在上方时 Y 就是负数

// ❌ BUG: 用 insetBy 扩大检查范围
let expanded = screen.frame.insetBy(dx: -200, dy: -200)
if !expanded.contains(center) { return }  // 扩大 200px 也不够

// ❌ BUG: 检查 origFrame 是否"看起来合理"
if origFrame.origin.x < 0 || origFrame.origin.y < 0 { return }
```

### 为什么 isValid() 不会出问题？

`ToggleRecord.isValid()` 在 `shouldRestoreCurrentWindow()` 中调用，它只检查：
- origFrame 的 Cocoa 中心不在主屏上（原始窗口确实不在主屏）
- targetFrame 的 Cocoa 中心在主屏上（目标确实在主屏）

这个检查验证的是**数据逻辑一致性**（orig 不在主屏 AND target 在主屏），
不是验证坐标是否"在物理屏幕上"。

## 已知的错误 commit（部分）

以下 commit 都是这个 bug 的重复出现：
- `ae491aa` — 移除了 origFrame "off-screen" 验证（2026-05-25）
- 旧代码注释已记录："isNearTarget 守卫已移除 — 此时恰恰是需要 restore 的场景"
- RestoreWatchdog (已删除) 中的轮询验证也有同类问题

## 防范规则

1. **restore 执行路径中不要加任何坐标/屏幕验证**
   - `shouldRestoreCurrentWindow()` → `isValid()` 是唯一需要的验证
   - restore 本身就是"把窗口放到保存的位置"，不需要检查位置是否"合理"

2. **如果要验证，在 save 时验证，不在 restore 时验证**
   - save 时知道当前屏幕布局，可以检查坐标是否合理
   - restore 时屏幕布局可能已经变了，验证会误杀

3. **任何新加的验证必须通过 RestoreGuardTests**
   - 测试文件：`Tests/Standalone/RestoreGuardTests.swift`
   - 覆盖了所有屏幕排列、断开连接、负坐标场景

4. **永远不要假设"负坐标 = 错误"**
   - Quartz 坐标系中，副屏在主屏上方时 Y 值为负
   - 副屏在主屏左边时 X 值为负
   - 这些都是完全合法的窗口位置

## 快速排查

当"按 Ctrl+Q 没反应（restore 不工作）"时：

```bash
# 检查日志中是否有坐标被拒绝的记录
grep "off-screen\|not on any screen\|invalid.*frame\|rejected.*orig" ~/Library/Logs/VibeFocus/vibefocus.log | tail -5

# 检查 ToggleRecord 是否存在
grep "ToggleEngine.*load\|no toggle record" ~/Library/Logs/VibeFocus/vibefocus.log | tail -5

# 检查 restore 是否被调用但提前返回
grep "restore:.*\|shouldRestore.*false" ~/Library/Logs/VibeFocus/vibefocus.log | tail -10
```
