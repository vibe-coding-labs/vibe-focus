# 屏幕索引面板可定制功能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 支持用户自定义屏幕索引面板的背景色、文字颜色和面板大小

**Architecture:** 在 ScreenIndexPreferences 中新增背景色、文字颜色、面板大小配置项，在 SettingsUI 中添加颜色选择器和滑块控件，在 OverlayWindow 中应用这些设置替代当前硬编码值

**Tech Stack:** Swift, SwiftUI, AppKit, CFPreferences API

---

## 文件结构

- `Sources/ScreenIndexPreferences.swift` - 新增颜色和大小的配置字段
- `Sources/SettingsUI.swift` - 添加颜色选择器和大小滑块 UI
- `Sources/OverlayWindow.swift` - 使用配置值替代硬编码颜色/大小

---

### Task 1: 扩展 ScreenIndexPreferences 数据结构

**Files:**
- Modify: `Sources/ScreenIndexPreferences.swift:37-55`

- [ ] **Step 1: 在 ScreenIndexPreferences 中添加新字段**

在 ScreenIndexPreferences 结构体中添加：
- `backgroundColor: CodableColor` - 背景色（已有但未使用）
- `textColor: CodableColor` - 文字颜色（已有但未使用）
- `panelScale: CGFloat` - 面板缩放比例（0.5 - 2.0，默认 1.0）

```swift
struct ScreenIndexPreferences: Codable {
    var isEnabled: Bool
    var position: IndexPosition
    var fontSize: CGFloat
    var opacity: CGFloat
    var textColor: CodableColor
    var backgroundColor: CodableColor
    var panelScale: CGFloat  // 新增：面板缩放比例
    var yabaiPath: String?

    static let `default` = ScreenIndexPreferences(
        isEnabled: false,
        position: .topRight,
        fontSize: 48,
        opacity: 0.8,
        textColor: CodableColor(.white),
        backgroundColor: CodableColor(.black.opacity(0.6)),
        panelScale: 1.0,  // 默认不缩放
        yabaiPath: nil
    )
}
```

- [ ] **Step 2: 验证编译通过**

Run: `swift build`
Expected: Build successful

---

### Task 2: 在 SettingsUI 中添加颜色选择器

**Files:**
- Modify: `Sources/SettingsUI.swift`

- [ ] **Step 1: 参考现有 fontSize 滑块，添加 panelScale 滑块**

在 Settings 视图中添加：

```swift
VStack(alignment: .leading, spacing: 8) {
    Text("面板大小: \(String(format: "%.1f", preferences.panelScale))x")
        .font(.subheadline)
    Slider(value: $preferences.panelScale, in: 0.5...2.0, step: 0.1)
}
```

- [ ] **Step 2: 添加背景色选择器**

使用 ColorPicker：

```swift
VStack(alignment: .leading, spacing: 8) {
    Text("背景颜色")
        .font(.subheadline)
    ColorPicker("", selection: Binding(
        get: { preferences.backgroundColor.swiftUIColor },
        set: { preferences.backgroundColor = CodableColor($0) }
    ))
    .labelsHidden()
}
```

- [ ] **Step 3: 添加文字颜色选择器**

```swift
VStack(alignment: .leading, spacing: 8) {
    Text("文字颜色")
        .font(.subheadline)
    ColorPicker("", selection: Binding(
        get: { preferences.textColor.swiftUIColor },
        set: { preferences.textColor = CodableColor($0) }
    ))
    .labelsHidden()
}
```

- [ ] **Step 4: 验证编译通过**

Run: `swift build`
Expected: Build successful

---

### Task 3: 在 OverlayWindow 中应用配置值

**Files:**
- Modify: `Sources/OverlayWindow.swift`

- [ ] **Step 1: 修改 update 方法使用 preferences.backgroundColor**

替换硬编码的 systemBlue：

```swift
let bgColor = NSColor(preferences.backgroundColor.swiftUIColor).withAlphaComponent(preferences.opacity)
contentView?.layer?.backgroundColor = bgColor.cgColor
```

- [ ] **Step 2: 修改 update 方法使用 preferences.textColor**

替换硬编码的白色：

```swift
let textColor = NSColor(preferences.textColor.swiftUIColor)
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: textColor
]
```

- [ ] **Step 3: 应用 panelScale 缩放面板大小**

```swift
let baseHorizontalPadding: CGFloat = preferences.fontSize * 0.8
let baseVerticalPadding: CGFloat = preferences.fontSize * 0.5
let baseMinWidth: CGFloat = preferences.fontSize * 3.5
let baseMinHeight: CGFloat = preferences.fontSize * 2.0

// 应用缩放
let horizontalPadding = baseHorizontalPadding * preferences.panelScale
let verticalPadding = baseVerticalPadding * preferences.panelScale
let minWidth = baseMinWidth * preferences.panelScale
let minHeight = baseMinHeight * preferences.panelScale
```

- [ ] **Step 4: 验证编译通过**

Run: `swift build`
Expected: Build successful

---

### Task 4: 测试功能

**Files:**
- Test: 手动测试

- [ ] **Step 1: 运行应用并打开设置**

Run: `./scripts/dev-run.sh`

- [ ] **Step 2: 测试颜色选择器**

1. 点击设置中的背景色选择器，选择红色
2. 观察屏幕索引面板背景是否变红
3. 点击文字颜色选择器，选择黄色
4. 观察文字是否变黄

- [ ] **Step 3: 测试面板大小滑块**

1. 拖动面板大小滑块到 1.5
2. 观察面板是否变大
3. 拖动到 0.7
4. 观察面板是否变小

- [ ] **Step 4: 测试设置持久化**

1. 修改颜色和大小
2. 重启应用
3. 确认设置已保存

---

### Task 5: 提交变更

- [ ] **Step 1: 提交代码**

```bash
git add Sources/
git commit -m "feat: 支持自定义屏幕索引面板颜色和大"
```

- [ ] **Step 2: 推送到远程**

```bash
git push origin main
```

---

## 依赖关系

Task 1 → Task 2 → Task 3 → Task 4 → Task 5

所有任务必须按顺序执行，因为后续任务依赖前面的数据结构变更。
