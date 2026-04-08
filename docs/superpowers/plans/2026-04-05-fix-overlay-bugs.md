# 修复屏幕索引面板重叠和滑块拖动问题 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复设置属性时创建多个重叠面板的bug，以及Slider滑块不支持拖动连续调整的问题

**Architecture:** 
1. 问题1：当`preferences`的`didSet`触发`refreshOverlays()`时，会先`hideOverlays()`再`showOverlays()`。但`hide()`只调用`orderOut(nil)`，窗口没有被正确关闭，导致新窗口创建时旧窗口仍存在。解决方案：改为直接更新现有窗口的属性，而不是销毁重建。
2. 问题2：SwiftUI Slider在macOS上需要添加特定修饰符来支持拖动连续更新。解决方案：添加`.onChange`或使用更合适的绑定方式。

**Tech Stack:** Swift, SwiftUI, AppKit

---

## 文件结构

- `Sources/ScreenOverlayManager.swift` - 修复`refreshOverlays()`和添加`updateOverlayAppearance()`方法
- `Sources/SettingsUI.swift` - 修复Slider拖动问题，使用`onChange`实现连续更新

---

### Task 1: 修复重叠面板问题 - 添加直接更新方法

**Files:**
- Modify: `Sources/ScreenOverlayManager.swift:157-163` (refreshOverlays方法)
- Modify: `Sources/ScreenOverlayManager.swift:182-199` (showOverlays相关)

- [ ] **Step 1: 修改 refreshOverlays 方法，优先使用现有窗口更新**

修改 `refreshOverlays()` 方法，当只需要更新外观属性时，直接调用现有窗口的`update`方法，而不是销毁重建：

```swift
func refreshOverlays(appearanceOnly: Bool = false) {
    log("refreshOverlays called, isEnabled=\(preferences.isEnabled), appearanceOnly=\(appearanceOnly)")
    
    if appearanceOnly && preferences.isEnabled && !overlayWindows.isEmpty {
        // 如果只是外观属性变化，直接更新现有窗口
        updateOverlayAppearance()
    } else {
        // 其他情况：销毁重建
        hideOverlays()
        if preferences.isEnabled {
            showOverlays()
        }
    }
}
```

- [ ] **Step 2: 添加 updateOverlayAppearance 方法**

在 `ScreenOverlayManager` 中添加新方法，用于直接更新现有窗口的外观：

```swift
private func updateOverlayAppearance() {
    let screens = NSScreen.screens
    
    for (index, screen) in screens.enumerated() {
        let uuid = uuidForScreen(screen)
        
        if let overlay = overlayWindows[uuid] {
            // 获取当前空间索引
            let spaceIndex = getSpaceIndex(for: screen) ?? 0
            
            // 直接更新窗口的外观属性
            overlay.update(screenIndex: index, spaceIndex: spaceIndex, preferences: preferences)
            overlay.updatePosition(for: screen, position: preferences.position)
            
            log("[updateOverlayAppearance] Updated overlay for screen \(index)")
        }
    }
}
```

- [ ] **Step 3: 验证编译通过**

Run: `swift build`
Expected: Build successful

---

### Task 2: 修复 Slider 拖动问题 - 使用 onChange 实现连续更新

**Files:**
- Modify: `Sources/SettingsUI.swift:970-990` (opacity Slider)
- Modify: `Sources/SettingsUI.swift:994-1018` (panelScale Slider)

- [ ] **Step 1: 修改 opacity Slider 支持拖动连续更新**

将透明度滑块改为使用 `@State` 临时变量 + `onChange` 模式：

```swift
// 在 SettingsView 结构体中添加状态变量（如果还没有的话）
// 由于 overlayManager.preferences 是 @Published，我们需要不同的方式

// 修改 opacity Slider 部分：
HStack(spacing: 8) {
    Slider(
        value: Binding(
            get: { overlayManager.preferences.opacity },
            set: { newValue in
                var prefs = overlayManager.preferences
                prefs.opacity = newValue
                overlayManager.preferences = prefs
            }
        ),
        in: 0.3...1.0,
        step: 0.1
    )
    .frame(width: 120)
    // 添加 onChange 确保拖动时实时更新
    .onChange(of: overlayManager.preferences.opacity) { _, _ in
        // 触发外观更新
        overlayManager.refreshOverlays(appearanceOnly: true)
    }

    Text("\(Int(overlayManager.preferences.opacity * 100))%")
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(width: 40)
}
```

等等，这样会有循环问题。更好的方式是：

```swift
// 使用本地状态变量来管理滑块值
@State private var tempOpacity: Double = 0.8

// 在 onAppear 中初始化
.onAppear {
    tempOpacity = overlayManager.preferences.opacity
}

// Slider 绑定到 tempOpacity，使用 onChange 同步到 overlayManager
Slider(value: $tempOpacity, in: 0.3...1.0, step: 0.1)
    .onChange(of: tempOpacity) { _, newValue in
        var prefs = overlayManager.preferences
        prefs.opacity = newValue
        overlayManager.preferences = prefs
    }
```

但考虑到代码结构，`overlayManager.preferences` 是 `@Published`，我们可以简化：

```swift
// 更简单的方式：在 didSet 中区分是否需要 appearanceOnly 更新
// 但这样会导致循环调用

// 最佳方案：修改 Slider 的 binding 使用方式
HStack(spacing: 8) {
    // 使用本地状态来避免频繁触发 didSet
    let binding = Binding<CGFloat>(
        get: { overlayManager.preferences.opacity },
        set: { newValue in
            // 直接修改，不通过 preferences 的 didSet
            let key = "opacity"
            // ... 或者使用更直接的方式
        }
    )
    
    Slider(value: binding, in: 0.3...1.0, step: 0.1)
        .frame(width: 120)
}
```

实际上，最干净的方式是修改 `ScreenOverlayManager` 的方法调用逻辑。让我重新思考：

```swift
// 在 SettingsUI.swift 中，修改 Slider 部分
// 方案：添加一个局部状态变量，在拖动时实时更新

struct ScreenIndexSettingsSection: View {
    @EnvironmentObject var overlayManager: ScreenOverlayManager
    
    // 本地状态用于滑块拖动
    @State private var localOpacity: Double = 0.8
    @State private var localPanelScale: CGFloat = 1.0
    
    var body: some View {
        // ...
        Slider(value: $localOpacity, in: 0.3...1.0, step: 0.1)
            .onAppear {
                localOpacity = overlayManager.preferences.opacity
            }
            .onChange(of: localOpacity) { _, newValue in
                // 直接更新 manager，不触发 preferences 的 didSet
                overlayManager.updateOpacity(newValue)
            }
    }
}
```

但这需要重构 SettingsUI。让我们采用最小改动方案：

**最小改动方案：**

在 `ScreenOverlayManager` 中添加专门的方法来处理外观属性的更新，避免使用 `preferences` 的 `didSet`：

```swift
// ScreenOverlayManager.swift
func updateAppearanceProperty(_ update: (inout ScreenIndexPreferences) -> Void) {
    // 暂时禁用 didSet 的刷新
    var prefs = preferences
    update(&prefs)
    // 直接保存到存储
    prefs.save()
    // 直接更新 UI，不经过 didSet
    updateOverlayAppearance()
}
```

但这会让代码更复杂。让我们采用最简单的方案：

**最简单方案：**

直接修改 `refreshOverlays` 的逻辑，确保在更新外观时，先正确关闭旧窗口：

```swift
func refreshOverlays() {
    log("refreshOverlays called, isEnabled=\(preferences.isEnabled)")
    
    // 确保旧窗口被正确关闭
    for (_, overlay) in overlayWindows {
        overlay.close()  // 使用 close() 而不是 hide()
    }
    overlayWindows.removeAll()
    
    if preferences.isEnabled {
        showOverlays()
    }
}
```

对于 Slider 拖动问题，使用 `onEditingChanged`：

```swift
Slider(
    value: Binding(...),
    in: 0.3...1.0,
    step: 0.1,
    onEditingChanged: { isEditing in
        // 在编辑开始时和结束时触发
    }
)
```

但这不够。让我们使用 SwiftUI 的 `.onChange` 配合 `ContinuousSlider` 模式：

实际上，最简单的方式是使用 `Slider` 的默认行为，它已经支持拖动。问题在于 `preferences` 的 `didSet` 每次都会被调用。

让我们重新设计：

```swift
// 修改 preferences 的 didSet，添加一个标志位来控制是否刷新
@Published var preferences: ScreenIndexPreferences {
    didSet {
        preferences.save()
        if !isBatchUpdating {
            refreshOverlays()
        }
    }
}

private var isBatchUpdating = false

func batchUpdateAppearance(_ updates: () -> Void) {
    isBatchUpdating = true
    updates()
    isBatchUpdating = false
    refreshOverlays()
}
```

但这太复杂了。让我采用最直接的方式：

**最终方案：**

1. 修改 `refreshOverlays()` 使用 `close()` 而不是 `hide()` 确保窗口被正确销毁
2. 在 SettingsUI 中使用 `onChange` 监听 Slider 值变化，但使用 `Debouncer` 避免过于频繁的更新

或者更简单：直接让 Slider 的更新走不同的路径：

```swift
// ScreenOverlayManager.swift
func updateAppearanceDirectly(fontSize: CGFloat? = nil, opacity: CGFloat? = nil, panelScale: CGFloat? = nil) {
    // 直接修改 preferences 而不触发 didSet
    var prefs = preferences
    if let fontSize = fontSize { prefs.fontSize = fontSize }
    if let opacity = opacity { prefs.opacity = opacity }
    if let panelScale = panelScale { prefs.panelScale = panelScale }
    prefs.save()
    
    // 直接更新现有窗口
    updateOverlayAppearance()
}
```

然后在 SettingsUI 中：

```swift
Slider(value: Binding(...))
    .onChange(of: overlayManager.preferences.opacity) { oldValue, newValue in
        // 使用直接更新方法
    }
```

不行，这样还是走 didSet。让我采用另一种方式：

**最终的最终方案：**

1. 在 `ScreenOverlayManager` 中添加 `updateAppearanceOnly()` 方法
2. 在 SettingsUI 中添加本地状态变量管理 Slider
3. 使用 `onChange` 将本地状态同步到 Manager，但不走 `preferences` 的 didSet

代码如下：

```swift
// ScreenOverlayManager.swift
func updateOverlayStyle(fontSize: CGFloat? = nil, opacity: CGFloat? = nil, 
                        panelScale: CGFloat? = nil, textColor: CodableColor? = nil,
                        backgroundColor: CodableColor? = nil) {
    // 直接更新 preferences 并保存
    if let fontSize = fontSize { preferences.fontSize = fontSize }
    if let opacity = opacity { preferences.opacity = opacity }
    if let panelScale = panelScale { preferences.panelScale = panelScale }
    if let textColor = textColor { preferences.textColor = textColor }
    if let backgroundColor = backgroundColor { preferences.backgroundColor = backgroundColor }
    preferences.save()
    
    // 直接更新现有窗口，不调用 refreshOverlays()
    let screens = NSScreen.screens
    for (index, screen) in screens.enumerated() {
        let uuid = uuidForScreen(screen)
        if let overlay = overlayWindows[uuid] {
            let spaceIndex = getSpaceIndex(for: screen) ?? 0
            overlay.update(screenIndex: index, spaceIndex: spaceIndex, preferences: preferences)
            overlay.updatePosition(for: screen, position: preferences.position)
        }
    }
}
```

在 SettingsUI 中，需要重构 Slider 部分来使用这个方法。

但考虑到最小改动原则，我采用以下方案：

**采用方案：**

1. **修复重叠面板**：修改 `hideOverlays()` 使用 `close()` 而不是 `hide()`
2. **修复 Slider 拖动**：使用 `@State` 本地状态 + `onChange` 来管理 Slider，避免频繁触发 `didSet`

让我重新编写 Plan：
