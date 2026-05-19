# Refactor: 统一坐标体系模块 (CoordinateKit)

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 创建统一的坐标管理模块 `CoordinateKit`，封装所有屏幕坐标、工作区索引、窗口位置的计算和转换，消除散落在多个文件中的重复/不一致坐标逻辑。

**Architecture:** 新建 `Sources/Space/CoordinateKit.swift`，定义强类型坐标包装（`ScreenPoint`, `ScreenRect`, `DisplayIndex`, `SpaceIndex`）和所有转换函数。先创建模块，再逐步迁移 restore/toggle 路径中的坐标逻辑到统一 API。数据流：所有坐标查询 → CoordinateKit（唯一转换入口）→ 调用方使用强类型结果。

**Tech Stack:** Swift 5.9, macOS 14+, AppKit (NSScreen), CoreGraphics (CGDirectDisplayID), yabai

**Scope:** Medium
**Risk:** Medium — 改动共享基础设施，但新增模块不改变现有行为（渐进迁移）

**Risks:**
- Task 1 创建新模块，不影响现有代码 → Low risk
- Task 2 迁移 restore 路径，影响窗口还原正确性 → 缓解：保留 fallback，逐步替换
- Task 3 迁移 toggle 路径 → 缓解：依赖 Task 2 验证通过后再做

**Autonomy Level:** Full

---

### Task 1: 创建 CoordinateKit 模块 — 定义坐标类型和转换函数

**Depends on:** None
**Files:**
- Create: `Sources/Space/CoordinateKit.swift`

- [ ] **Step 1: 创建 CoordinateKit.swift — 定义所有坐标类型和转换 API**

文件: `Sources/Space/CoordinateKit.swift`

```swift
import AppKit
import CoreGraphics
import Foundation

// MARK: - 坐标体系类型定义

/// macOS 使用两套坐标系：
/// - Quartz (CoreGraphics): 原点在主屏左上角，Y 轴向下。AX API、CGWindowList、yabai 使用此坐标系。
/// - Cocoa (AppKit): 原点在主屏左下角，Y 轴向上。NSScreen 使用此坐标系。
/// 本模块统一使用 Quartz 坐标系作为内部标准，仅在需要与 NSScreen 交互时转换。

/// 显示器标识 — 封装三种不同的显示器索引方式
enum DisplayIdentifier: Equatable, CustomStringConvertible {
    /// yabai 的 1-based 显示器索引（display 1 = 主屏）
    case yabaiIndex(Int)
    /// NSScreen.screens 数组的 0-based 索引（index 0 = 主屏）
    case screenArrayIndex(Int)
    /// CoreGraphics 硬件级显示器标识符
    case cgDirectDisplayID(UInt32)

    var description: String {
        switch self {
        case .yabaiIndex(let i): return "yabai(\(i))"
        case .screenArrayIndex(let i): return "screen[\(i)]"
        case .cgDirectDisplayID(let id): return "cgDisplay(\(id))"
        }
    }
}

/// 工作区标识 — 封装两种不同的工作区索引方式
enum SpaceIdentifier: Equatable, CustomStringConvertible {
    /// yabai 的全局 space 索引（space 1 = 主屏第一个 space）
    case yabaiIndex(Int)
    /// macOS 原生 space ID（CGSPrivate 中的 space identifier）
    case nativeID(Int64)

    var description: String {
        switch self {
        case .yabaiIndex(let i): return "yabai_space(\(i))"
        case .nativeID(let id): return "native_space(\(id))"
        }
    }
}

/// 窗口坐标矩形 — 始终使用 Quartz 坐标系（原点在主屏左上角，Y 向下）
struct QuartzRect: Equatable, CustomStringConvertible {
    let origin: CGPoint
    let size: CGSize

    var x: CGFloat { origin.x }
    var y: CGFloat { origin.y }
    var width: CGFloat { size.width }
    var height: CGFloat { size.height }
    var midX: CGFloat { origin.x + size.width / 2 }
    var midY: CGFloat { origin.y + size.height / 2 }
    var maxX: CGFloat { origin.x + size.width }
    var maxY: CGFloat { origin.y + size.height }

    init(_ cgRect: CGRect) {
        self.origin = cgRect.origin
        self.size = cgRect.size
    }

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.origin = CGPoint(x: x, y: y)
        self.size = CGSize(width: width, height: height)
    }

    var cgRect: CGRect { CGRect(origin: origin, size: size) }

    var description: String { "\(Int(x)),\(Int(y)) \(Int(width))x\(Int(height))" }

    /// 判断此矩形中心点是否在给定 Quartz 帧 范围内
    func centerIsInside(_ screenFrame: CGRect) -> Bool {
        screenFrame.contains(CGPoint(x: midX, y: midY))
    }
}

// MARK: - 坐标转换

@MainActor
enum CoordinateKit {

    // MARK: 显示器相关

    /// 获取主屏的 Quartz 帧
    static var mainScreenQuartzFrame: CGRect? {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame ?? NSScreen.screens.first?.frame
    }

    /// 获取主屏高度（用于 Cocoa ↔ Quartz Y 轴转换）
    static var mainScreenHeight: CGFloat {
        mainScreenQuartzFrame?.height ?? NSScreen.screens.first?.frame.height ?? 0
    }

    /// NSScreen → Quartz 帧转换
    /// NSScreen 使用 Cocoa 坐标（Y-up），转换为 Quartz（Y-down）
    static func quartzFrame(fromNSScreen screen: NSScreen) -> CGRect {
        guard screen.frame.origin == .zero else {
            return screen.frame
        }
        return screen.frame
    }

    /// 获取屏幕的可用区域（去掉菜单栏和 Dock），返回 Quartz 坐标
    static func quartzVisibleFrame(of screen: NSScreen) -> CGRect {
        let visibleFrame = screen.visibleFrame
        if screen.frame.origin == .zero {
            let screenMaxY = screen.frame.maxY
            return CGRect(
                x: visibleFrame.origin.x,
                y: screenMaxY - visibleFrame.maxY,
                width: visibleFrame.width,
                height: visibleFrame.height
            )
        }
        return visibleFrame
    }

    /// 判断一个 Quartz 坐标点是否在主屏上
    static func isOnMainScreen(_ point: CGPoint) -> Bool {
        guard let mainFrame = mainScreenQuartzFrame else { return false }
        return mainFrame.contains(point)
    }

    /// 判断一个 Quartz 矩形是否在主屏上
    static func isOnMainScreen(_ rect: CGRect) -> Bool {
        guard let mainFrame = mainScreenQuartzFrame else { return false }
        return mainFrame.contains(CGPoint(x: rect.midX, y: rect.midY))
    }

    /// 根据 Quartz 坐标确定窗口所在的显示器
    static func displayIDForPoint(_ point: CGPoint) -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            let frame = screen.frame
            if frame.contains(convertQuartzToCocoa(point, screenFrame: frame)) {
                return screen.displayID ?? CGMainDisplayID()
            }
        }
        return nil
    }

    /// 根据 Quartz 矩形确定窗口所在的 NSScreen
    static func screenForRect(_ rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // 主屏的 Quartz 帧就是 origin==zero 的 screen.frame
        if let mainFrame = mainScreenQuartzFrame, mainFrame.contains(center) {
            return NSScreen.screens.first { $0.frame.origin == .zero }
        }
        // 副屏：遍历检查
        for screen in NSScreen.screens where screen.frame.origin != .zero {
            let screenQuartzFrame = screen.frame
            if screenQuartzFrame.contains(center) {
                return screen
            }
        }
        return nil
    }

    // MARK: 坐标系转换

    /// Quartz → Cocoa Y 轴转换（单个值）
    static func cocoaY(fromQuartzY quartzY: CGFloat) -> CGFloat {
        mainScreenHeight - quartzY
    }

    /// Cocoa → Quartz Y 轴转换（单个值）
    static func quartzY(fromCocoaY cocoaY: CGFloat) -> CGFloat {
        mainScreenHeight - cocoaY
    }

    /// Quartz CGPoint → Cocoa CGPoint（相对于指定 screen 的 frame）
    static func convertQuartzToCocoa(_ point: CGPoint, screenFrame: CGRect) -> CGPoint {
        if screenFrame.origin == .zero {
            return CGPoint(x: point.x, y: mainScreenHeight - point.y)
        }
        return point
    }

    // MARK: 显示器索引转换

    /// CGDirectDisplayID → NSScreen
    static func nsScreen(forCGDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    /// NSScreen → 0-based 数组索引
    static func screenArrayIndex(for screen: NSScreen) -> Int? {
        NSScreen.screens.firstIndex(where: { $0 == screen })
    }

    /// CGDirectDisplayID → 0-based 数组索引
    static func screenArrayIndex(forCGDisplayID displayID: CGDirectDisplayID) -> Int? {
        guard let screen = nsScreen(forCGDisplayID: displayID) else { return nil }
        return screenArrayIndex(for: screen)
    }

    /// NSScreen → CGDirectDisplayID
    static func cgDisplayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.displayID
    }

    /// yabai display index (1-based) → NSScreen
    /// yabai 的 display 1 = mainDisplay, display 2 = 第一个副屏
    static func nsScreen(forYabaiDisplayIndex index: Int) -> NSScreen? {
        let screens = NSScreen.screens
        guard index >= 1, index <= screens.count else { return nil }
        // yabai display 1 = 主屏 (screens[0])
        // yabai display 2 = 第一个副屏 (需要找到非主屏的 screen)
        if index == 1 {
            return screens.first { $0.frame.origin == .zero } ?? screens.first
        }
        let nonMainScreens = screens.filter { $0.frame.origin != .zero }
        let nonMainIndex = index - 2
        guard nonMainIndex >= 0, nonMainIndex < nonMainScreens.count else { return nil }
        return nonMainScreens[nonMainIndex]
    }

    // MARK: 窗口帧验证

    /// 验证两个帧是否在给定容差内匹配
    static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 10, heightTolerance: CGFloat? = nil) -> Bool {
        let ht = heightTolerance ?? tolerance * 2
        let positionMatches = abs(a.origin.x - b.origin.x) <= tolerance &&
                             abs(a.origin.y - b.origin.y) <= tolerance
        let sizeMatches = abs(a.width - b.width) <= tolerance * 2 &&
                         abs(a.height - b.height) <= ht
        return positionMatches && sizeMatches
    }

    /// 验证帧是否在预期屏幕上（防止坐标被 macOS 钳制到错误屏幕）
    static func isFrameOnExpectedScreen(_ frame: CGRect, expectedScreen: NSScreen) -> Bool {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return expectedScreen.frame.contains(center)
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    /// 获取屏幕的 CGDirectDisplayID
    var displayID: CGDirectDisplayID? {
        let key = "NSScreenNumber" as String
        return deviceDescription[key] as? CGDirectDisplayID
    }

    /// 是否是主屏（frame.origin == .zero）
    var isMainScreen: Bool { frame.origin == .zero }
}
```

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Space/CoordinateKit.swift && git commit -m "feat(coords): add CoordinateKit module — unified coordinate types and conversions"`

---

### Task 2: 迁移 ToggleEngine.restore 使用 CoordinateKit — 修复坐标钳制问题

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift` — restore 路径中添加屏幕验证

- [ ] **Step 1: 在 ToggleEngine.restore 的 AX apply 后添加屏幕验证**

文件: `Sources/Toggle/ToggleEngine.swift`（在 `restored = wm.apply(frame: record.origFrame, ...)` 之后）

当前问题：AX apply 返回 true（容差内匹配），但窗口可能在错误的屏幕上（macOS 钳制了坐标）。需要在 apply 成功后验证窗口确实在目标屏幕上。

找到 restore 路径中 AX apply 成功后的代码块：
```swift
restored = wm.apply(frame: record.origFrame, to: restoreAX, operationID: trace, stage: "restore_orig")

if restored {
    log("[ToggleEngine] restore: direct AX apply succeeded", ...)
}
```

替换为：
```swift
restored = wm.apply(frame: record.origFrame, to: restoreAX, operationID: trace, stage: "restore_orig")

if restored {
    // 验证窗口确实在目标屏幕上（AX apply 可能因坐标钳制返回 true 但窗口在错误屏幕）
    if let postFrame = wm.frame(of: restoreAX) {
        let onExpectedScreen: Bool
        if record.sourceYabaiDisp == 1 {
            onExpectedScreen = CoordinateKit.isOnMainScreen(postFrame)
        } else {
            onExpectedScreen = !CoordinateKit.isOnMainScreen(postFrame)
        }
        if !onExpectedScreen {
            log("[ToggleEngine] restore: AX apply succeeded but window on WRONG screen, marking as failed", level: .warn, fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "postFrame": "\(postFrame)",
                "expectedDisplay": String(record.sourceYabaiDisp)
            ])
            restored = false
        } else {
            log("[ToggleEngine] restore: direct AX apply succeeded with correct screen", fields: [
                "traceID": trace,
                "windowID": String(windowID),
                "origFrame": "\(record.origFrame)"
            ])
        }
    }
}
```

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 构建部署并验证**
Run: `bash scripts/dev-build.sh 2>&1 | tail -5 && pkill -x VibeFocus; sleep 1; open /Applications/VibeFocus.app; sleep 3; tail -10 /Users/cc11001100/Library/Logs/VibeFocus/vibefocus.log | grep -i "error\|crash\|fatal" || echo "No errors"`
Expected:
  - Output contains: "构建成功"
  - Output contains: "No errors"

- [ ] **Step 4: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "fix(restore): add screen verification after AX apply — detect coordinate clamping to wrong screen"`

---

### Task 3: 迁移 WindowManager 坐标逻辑到 CoordinateKit — 统一屏幕判断

**Depends on:** Task 2
**Files:**
- Modify: `Sources/Window/WindowManager+ScreenPosition.swift` — 用 CoordinateKit 替换散落的坐标转换

- [ ] **Step 1: 在 ScreenPosition.swift 中用 CoordinateKit 替换 `isWindowOnMainScreen` 的坐标转换**

文件: `Sources/Window/WindowManager+ScreenPosition.swift`

找到 `isWindowOnMainScreen` 函数中的坐标转换逻辑。当前代码通过 CGWindowList 获取窗口帧，然后手动转换 Cocoa/Quartz 坐标来判断窗口是否在主屏。

用 `CoordinateKit.isOnMainScreen()` 替换手动坐标转换，确保所有屏幕判断逻辑使用统一的标准。

- [ ] **Step 2: 用 CoordinateKit 替换 `displayContext` 和 `axFrame(forVisibleFrameOf:)` 中的坐标转换**

文件: `Sources/Window/WindowManager+ScreenPosition.swift`

找到 `displayContext(for:)` 函数（将 CGRect 映射到显示器上下文）和 `axFrame(forVisibleFrameOf:)` 函数（将 NSScreen.visibleFrame 转为 AX 坐标）。用 `CoordinateKit.quartzVisibleFrame()` 替换 `axFrame(forVisibleFrameOf:)` 的手动转换。

- [ ] **Step 3: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 构建部署并验证**
Run: `bash scripts/dev-build.sh 2>&1 | tail -5 && pkill -x VibeFocus; sleep 1; open /Applications/VibeFocus.app; sleep 3; tail -10 /Users/cc11001100/Library/Logs/VibeFocus/vibefocus.log | grep -i "error\|crash\|fatal" || echo "No errors"`
Expected:
  - Output contains: "构建成功"
  - Output contains: "No errors"

- [ ] **Step 5: 提交**
Run: `git add Sources/Window/WindowManager+ScreenPosition.swift && git commit -m "refactor(coords): migrate ScreenPosition to CoordinateKit — unified screen coordinate conversion"`

---

### Task 4: 添加坐标调试日志 — 每次 restore 记录完整坐标上下文

**Depends on:** Task 2
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift` — 在 restore 开始和结束时记录坐标上下文

- [ ] **Step 1: 在 ToggleEngine.restore 中添加坐标上下文日志**

文件: `Sources/Toggle/ToggleEngine.swift`（在 restore 方法中 record 加载之后、frame 操作之前）

在 record 加载成功后，记录完整的坐标上下文：
```swift
log("[ToggleEngine] restore: coordinate context", fields: [
    "traceID": trace,
    "windowID": String(windowID),
    "origFrame": CoordinateKit.QuartzRect(record.origFrame).description,
    "sourceYabaiDisp": String(record.sourceYabaiDisp),
    "sourceSpace": String(record.sourceSpace),
    "mainScreenFrame": CoordinateKit.mainScreenQuartzFrame.map { "\($0)" } ?? "nil",
    "currentScreens": NSScreen.screens.map { "\($0.frame)" }.joined(separator: " | ")
])
```

同时在 restore 结束时（无论成功失败），记录最终窗口位置和所在屏幕：
```swift
if let finalFrame = wm.frame(of: restoreAX) {
    log("[ToggleEngine] restore: final frame", fields: [
        "traceID": trace,
        "windowID": String(windowID),
        "finalFrame": CoordinateKit.QuartzRect(finalFrame).description,
        "onMainScreen": String(CoordinateKit.isOnMainScreen(finalFrame))
    ])
}
```

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 构建部署并验证**
Run: `bash scripts/dev-build.sh 2>&1 | tail -5`
Expected:
  - Output contains: "构建成功"

- [ ] **Step 4: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "feat(coords): add coordinate context logging to restore — full Quartz frame + screen diagnostics"`
