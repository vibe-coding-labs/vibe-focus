# 修复 Ctrl+M 切换窗口高延迟 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 Ctrl+M 切换窗口时的高延迟问题

**Architecture:** SpaceController 中同步执行 yabai 命令阻塞主线程，需要将空间检测改为异步，并减少不必要的 yabai 调用

**Tech Stack:** Swift, yabai

---

## 问题分析

1. `SpaceController.captureSpaceContext()` 同步执行两个 yabai 命令（`currentSpaceIndex()` 和 `windowSpaceIndex()`）
2. 每次 `toggle()` 调用都会触发同步的 yabai 进程执行，阻塞主线程
3. `log()` 函数每次写入文件系统也可能造成延迟

---

### Task 1: 优化 SpaceController 减少同步调用

**Files:**
- Modify: `Sources/SpaceController.swift`
- Modify: `Sources/WindowManager.swift`

- [ ] **Step 1: 在 SpaceController 中添加缓存机制**

添加空间索引缓存，避免每次调用都查询 yabai：

```swift
// 添加缓存
private var cachedCurrentSpace: Int?
private var cachedWindowSpaces: [UInt32: Int] = [:]
private var cacheTimestamp: Date?
private let cacheValidity: TimeInterval = 0.5  // 500ms 缓存
```

- [ ] **Step 2: 添加缓存验证方法**

```swift
private func isCacheValid() -> Bool {
    guard let timestamp = cacheTimestamp else { return false }
    return Date().timeIntervalSince(timestamp) < cacheValidity
}

private func invalidateCache() {
    cachedCurrentSpace = nil
    cachedWindowSpaces.removeAll()
    cacheTimestamp = nil
}
```

- [ ] **Step 3: 修改 currentSpaceIndex 使用缓存**

```swift
func currentSpaceIndex() -> Int? {
    refreshAvailabilityIfNeeded()
    guard isEnabled else { return nil }
    
    // 使用缓存
    if isCacheValid(), let cached = cachedCurrentSpace {
        return cached
    }
    
    guard let space = queryFocusedSpace() else { return nil }
    cachedCurrentSpace = space.index
    cacheTimestamp = Date()
    return space.index
}
```

- [ ] **Step 4: 修改 windowSpaceIndex 使用缓存**

```swift
func windowSpaceIndex(windowID: UInt32) -> Int? {
    refreshAvailabilityIfNeeded()
    guard isEnabled else { return nil }
    
    // 使用缓存
    if isCacheValid(), let cached = cachedWindowSpaces[windowID] {
        return cached
    }
    
    guard let window = queryWindow(windowID: windowID) else { return nil }
    cachedWindowSpaces[windowID] = window.space
    return window.space
}
```

- [ ] **Step 5: 在窗口移动后自动失效缓存**

在 `moveWindow` 和 `focusSpace` 成功后调用 `invalidateCache()`

---

### Task 2: 将空间检测改为异步

**Files:**
- Modify: `Sources/WindowManager.swift`

- [ ] **Step 1: 修改 moveToMainScreen 异步获取空间上下文**

将 `captureSpaceContext` 改为异步执行，不阻塞窗口移动：

```swift
func moveToMainScreen() {
    log("=== MOVE TO MAIN SCREEN ===")
    
    // ... 前面的代码 ...
    
    // 异步获取空间上下文，不阻塞窗口移动
    let spaceContext = spaceController.isEnabled 
        ? spaceController.captureSpaceContextAsync(windowID: currentWindowID)
        : SpaceContext(sourceSpaceIndex: nil, targetSpaceIndex: nil)
    
    // 窗口移动操作...
}
```

- [ ] **Step 2: 在 WindowManager 中异步保存状态**

创建异步保存方法，空间信息可以稍后再补充：

```swift
private func saveWindowStateAsync(_ state: SavedWindowState, window: AXUIElement) {
    // 先立即保存基本信息（不含空间）
    hydrateMemory(from: state, window: window)
    
    // 异步获取完整空间信息再更新
    if spaceController.isEnabled {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let context = self?.spaceController.captureSpaceContext(windowID: state.windowID ?? 0)
            DispatchQueue.main.async {
                var updatedState = state
                updatedState.sourceSpaceIndex = context?.sourceSpaceIndex
                updatedState.targetSpaceIndex = context?.targetSpaceIndex
                self?.persistState(updatedState)
            }
        }
    }
}
```

---

### Task 3: 优化日志性能

**Files:**
- Modify: `Sources/Support.swift`

- [ ] **Step 1: 添加日志批处理或降低写入频率**

使用内存缓冲，定期批量写入：

```swift
// 添加日志缓冲
private var logBuffer: [String] = []
private let logQueue = DispatchQueue(label: "vibefocus.log")
private var logTimer: Timer?

func log(_ message: String) {
    NSLog("[VibeFocus] %@", message)
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)"
    
    logQueue.async {
        logBuffer.append(line)
        
        // 每 10 条或每秒写入一次
        if logBuffer.count >= 10 {
            flushLogBuffer()
        }
    }
}

private func flushLogBuffer() {
    guard !logBuffer.isEmpty else { return }
    let lines = logBuffer.joined(separator: "\n") + "\n"
    logBuffer.removeAll()
    
    let logURL = URL(fileURLWithPath: "/tmp/vibefocus.log")
    if let data = lines.data(using: .utf8) {
        // 写入文件...
    }
}
```

---

### Task 4: 验证修复

**Files:**
- Test: 手动测试

- [ ] **Step 1: 编译测试**

Run: `swift build`
Expected: 编译成功

- [ ] **Step 2: 测试 Ctrl+M 响应速度**

运行应用，多次按 Ctrl+M 测试响应速度
Expected: 切换窗口响应迅速，无明显延迟

- [ ] **Step 3: 测试空间恢复功能**

测试跨工作区窗口恢复功能是否正常工作
Expected: 空间检测和恢复功能正常

---

### Task 5: 提交修复

- [ ] **Step 1: 提交代码**

```bash
git add Sources/
git commit -m "perf: 优化 Ctrl+M 切换窗口延迟"
```

- [ ] **Step 2: 推送到远程**

```bash
git push origin main
```

---

## 依赖关系

Task 1 → Task 2 → Task 3 → Task 4 → Task 5
