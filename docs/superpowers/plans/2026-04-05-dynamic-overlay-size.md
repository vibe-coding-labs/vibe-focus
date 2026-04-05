# OverlayWindow 动态面板大小调整计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 OverlayWindow 面板大小不能根据字体大小动态调整的问题，确保调整字体大小时面板大小也相应变化

**Architecture:** 修改 OverlayWindow.swift 中的尺寸计算逻辑，使其基于字体大小动态计算最小尺寸和边距，而不是使用固定值

**Tech Stack:** Swift, AppKit

---

## 当前问题分析

在 `OverlayWindow.swift` 中，当前的尺寸计算逻辑存在问题：

```swift
// 当前实现的问题
let textSize = label.attributedStringValue.size()
let padding: CGFloat = 16  // 固定边距
let width = max(textSize.width + padding * 2, 80)  // 固定最小宽度 80
let height = max(textSize.height + padding, 60)    // 固定最小高度 60
```

**问题：**
1. 最小宽度/高度是固定的（80x60），不会随字体大小变化
2. 边距固定为16，对于大字体来说可能不够
3. 当字体变得很大时，文本会被截断或超出面板

## 解决方案

基于字体大小动态计算：
1. **动态最小尺寸**：基于字体大小计算最小宽高
2. **动态边距**：边距随字体大小比例调整
3. **适当的比例系数**：确保大字体有足够的显示空间

---

## 文件结构

| 文件 | 职责 |
|------|------|
| `Sources/OverlayWindow.swift` | 修改尺寸计算逻辑，基于字体大小动态调整 |

---

### Task 1: 修改 OverlayWindow 尺寸计算逻辑

**Files:**
- Modify: `Sources/OverlayWindow.swift`

- [ ] **Step 1: 分析当前尺寸计算代码**

当前代码位置（约58-64行）：
```swift
let textSize = label.attributedStringValue.size()
let padding: CGFloat = 16
let width = max(textSize.width + padding * 2, 80)
let height = max(textSize.height + padding, 60)
```

- [ ] **Step 2: 修改为动态尺寸计算**

将尺寸计算部分修改为基于字体大小的动态计算：

```swift
func update(screenIndex: Int, spaceIndex: Int, preferences: ScreenIndexPreferences) {
    self.screenIndex = screenIndex
    self.spaceIndex = spaceIndex

    // 更新标签文本和字体
    label.stringValue = "\(screenIndex)-\(spaceIndex)"
    label.font = .systemFont(ofSize: preferences.fontSize, weight: .bold)
    label.textColor = NSColor(preferences.textColor.swiftUIColor)

    // 更新背景
    contentView?.wantsLayer = true
    contentView?.layer?.backgroundColor = NSColor(
        preferences.backgroundColor.swiftUIColor.opacity(preferences.opacity)
    ).cgColor
    contentView?.layer?.cornerRadius = 8

    // 动态计算尺寸（基于字体大小）
    let textSize = label.attributedStringValue.size()
    
    // 动态边距：基于字体大小的比例
    let horizontalPadding: CGFloat = preferences.fontSize * 0.5  // 字体大小的50%
    let verticalPadding: CGFloat = preferences.fontSize * 0.4     // 字体大小的40%
    
    // 动态最小尺寸：确保即使文本很短也有足够的空间
    let minWidth: CGFloat = preferences.fontSize * 2.5   // 至少能显示2.5个字符宽度
    let minHeight: CGFloat = preferences.fontSize * 1.5  // 至少1.5倍字体高度
    
    let width = max(textSize.width + horizontalPadding * 2, minWidth)
    let height = max(textSize.height + verticalPadding * 2, minHeight)

    label.frame = CGRect(x: horizontalPadding, y: verticalPadding, 
                         width: textSize.width, height: textSize.height)
    self.setContentSize(CGSize(width: width, height: height))
}
```

- [ ] **Step 3: 验证标签位置居中**

确保标签在面板中居中显示：

```swift
// 居中标签
label.frame = CGRect(
    x: (width - textSize.width) / 2,
    y: (height - textSize.height) / 2,
    width: textSize.width,
    height: textSize.height
)
```

- [ ] **Step 4: 测试不同字体大小**

手动测试验证：
1. 打开应用设置
2. 尝试不同字体大小（24, 48, 72, 96）
3. 观察面板大小是否随字体大小正确调整
4. 确保文本不会被截断

---

## 备选方案（如果上述方案不理想）

### 方案 B: 固定比例缩放

使用更简单的固定比例：

```swift
let scaleFactor: CGFloat = preferences.fontSize / 48.0  // 以48为基准
let padding: CGFloat = 16 * scaleFactor
let minWidth: CGFloat = 80 * scaleFactor
let minHeight: CGFloat = 60 * scaleFactor
```

---

## 预期效果

| 字体大小 | 当前面板大小 | 优化后面板大小 |
|----------|--------------|----------------|
| 24pt | 80x60 | ~60x48 |
| 48pt | 80x60 | ~100x72 |
| 72pt | 80x60 | ~140x100 |
| 96pt | 80x60 | ~180x130 |

面板大小将随字体大小成比例调整，确保：
1. 文本不会被截断
2. 有足够的内边距
3. 视觉效果协调

---

## 风险评估

| 风险 | 可能性 | 缓解措施 |
|------|--------|----------|
| 面板变得太大 | 低 | 设置合理的最大尺寸限制 |
| 面板变得太小 | 低 | 设置基于字体的最小尺寸 |
| 文本截断 | 低 | 充分测试各种字体大小 |
